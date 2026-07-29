#!/usr/bin/env bash
# Safely inspect, transfer, and restore Firstmate primary sessions.
#
# Usage:
#   fm-primary-session.sh scan [--json]
#       Read-only fleet-wide scan of local Paseo sessions with pending
#       permissions or another structured captain-action marker.
#
#   fm-primary-session.sh takeover <paseo-agent-id>
#       Prove that the exact local Paseo agent owns this home's live numeric
#       session lock, classify it from structured Paseo and quota evidence,
#       refuse every unsafe state, soft-archive the idle recoverable provider,
#       verify the captured owner process tree is gone, publish an append-only
#       privacy-safe receipt, acquire the unchanged stale numeric lock through
#       bin/fm-lock.sh, and run the ordinary session-start digest.
#
#   fm-primary-session.sh restore <receipt-id>
#       Refuse while any recorded lock pid is alive, mark the receipt as a
#       restore request under the lock-acquisition mutex, and reload the exact
#       archived Paseo agent.
#       The restored Claude or Codex provider's tracked native session-start
#       hook must then run bin/fm-session-start.sh before any Firstmate
#       mutation.
#       Successful reacquisition appends state=restored to the receipt.
#
# Supported recoverable source sessions in v1 are local Paseo-hosted Claude
# and Codex primaries whose provider reports session persistence.
# OpenCode, Pi, pi-signed, Grok, Kimi, Codex Desktop, remote Paseo hosts, and
# unmanaged terminal sessions are classified as unsupported rather than
# approximated.
# Task runtime backends are orthogonal: tmux, Herdr, Zellij, Orca, and cmux
# metadata and endpoints are never touched by this command.
#
# Safety:
#   - The numeric state/.lock remains authoritative.
#   - No command unlinks or overwrites a live owner's lock.
#   - takeover never passes Paseo's --force flag.
#   - takeover and restore serialize with ordinary acquisition through
#     state/.lock.acquire.
#   - receipts contain ids, classifications, timestamps, and hashes only.
#     They never contain credentials, permission descriptions, or prompts.
#   - scan performs no writes and omits prompt/title/permission prose.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LOCK="$STATE/.lock"
CLAIM_LOCK="$STATE/.lock.acquire"
HANDOFF_DIR="$DATA/primary-session-handoffs"
FM_PRIMARY_WEDGE_SECS=${FM_PRIMARY_WEDGE_SECS:-600}
FM_PRIMARY_OWNER_EXIT_TIMEOUT=${FM_PRIMARY_OWNER_EXIT_TIMEOUT:-15}
FM_PRIMARY_RELOAD_TIMEOUT=${FM_PRIMARY_RELOAD_TIMEOUT:-10}

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-primary-session-lib.sh
. "$SCRIPT_DIR/fm-primary-session-lib.sh"

die() {
  printf 'primary-session: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n \
    -e '2,/^set -u$/s/^# //p' \
    -e '2,/^set -u$/s/^#$//p' \
    "$0"
}

require_read_tools() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v paseo >/dev/null 2>&1 || die "paseo is required"
}

require_takeover_tools() {
  require_read_tools
  command -v quota-axi >/dev/null 2>&1 || die "quota-axi is required for deterministic idle versus rate-limited classification"
}

primary_scope_required() {
  fm_is_gate_agent "$FM_ROOT" && die "refusing inside a no-mistakes gate agent"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" \
    || die "refusing outside a genuine Firstmate primary home"
}

paseo_inspect() {
  paseo agent inspect "$1" --json
}

paseo_agent_record() {
  local agent_file
  agent_file=$(fm_primary_paseo_agent_file "$1") || return 1
  [ -f "$agent_file" ] && [ ! -L "$agent_file" ] || return 1
  jq -e '.' "$agent_file"
}

iso_epoch() {
  local raw=$1 normalized
  normalized=$(sed -E 's/\.[0-9]+Z$/Z/' <<< "$raw")
  if date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$normalized" '+%s' >/dev/null 2>&1; then
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$normalized" '+%s' 2>/dev/null
  else
    date -u -d "$normalized" '+%s' 2>/dev/null
  fi
}

quota_classification() {
  local provider=$1 quota provider_count state_ok blocked
  quota=$(quota-axi --provider "$provider" --json 2>/dev/null) || return 1
  provider_count=$(jq --arg provider "$provider" '[.providers[]? | select(.provider == $provider)] | length' <<< "$quota") || return 1
  [ "$provider_count" = 1 ] || return 1
  state_ok=$(jq -r --arg provider "$provider" '
    [.providers[]? | select(.provider == $provider)][0]
    | (.state.status == "fresh" and .state.stale == false)
  ' <<< "$quota") || return 1
  [ "$state_ok" = true ] || return 1
  blocked=$(jq -r --arg provider "$provider" '
    [.providers[]? | select(.provider == $provider)][0]
    | any(.windows[]?;
        ((.kind == "session") or (.kind == "weekly"))
        and ((.percentRemaining | numbers) <= 0))
  ' <<< "$quota") || return 1
  if [ "$blocked" = true ]; then
    printf 'rate-limited\n'
  else
    printf 'available\n'
  fi
}

target_has_attached_children() {
  local target=$1 list row child_id child
  list=$(paseo agent ls --global --json 2>/dev/null) || return 2
  jq -e 'type == "array" and all(.[]; (.id | type) == "string")' <<< "$list" >/dev/null || return 2
  while IFS= read -r row; do
    child_id=$(jq -r '.id' <<< "$row") || return 2
    [ "$child_id" = "$target" ] && continue
    child=$(paseo_inspect "$child_id" 2>/dev/null) || return 2
    jq -e '.Id and (.Archived | type == "boolean")' <<< "$child" >/dev/null || return 2
    if [ "$(jq -r '.Archived' <<< "$child")" = false ] \
      && [ "$(jq -r '.ParentAgentId // empty' <<< "$child")" = "$target" ]; then
      return 0
    fi
  done < <(jq -c '.[]' <<< "$list")
  return 1
}

classify_target() {
  local owner_pid=$1 agent_id=$2 owner_harness=$3 inspect record provider status record_status archived
  local persistence pending parent requires_attention attention_reason last_user last_activity unresolved=0
  local quota_state now user_epoch activity_epoch age children_rc target_cwd resolved_target_cwd resolved_root
  inspect=$(paseo_inspect "$agent_id" 2>/dev/null) || {
    printf 'unknown|Paseo inspection failed\n'
    return 0
  }
  record=$(paseo_agent_record "$agent_id" 2>/dev/null) || {
    printf 'unknown|local Paseo state is missing, symlinked, or unreadable\n'
    return 0
  }
  if ! jq -e '
    (.Id | type) == "string"
    and (.Provider | type) == "string"
    and (.Status | type) == "string"
    and (.Archived | type) == "boolean"
    and (.Cwd | type) == "string"
    and (.Capabilities.Persistence | type) == "boolean"
    and (.PendingPermissions | type) == "array"
  ' <<< "$inspect" >/dev/null; then
    printf 'unknown|Paseo inspection schema is incomplete\n'
    return 0
  fi
  [ "$(jq -r '.Id' <<< "$inspect")" = "$agent_id" ] || {
    printf 'unknown|Paseo resolved a different agent id\n'
    return 0
  }
  [ "$(jq -r '.id // empty' <<< "$record")" = "$agent_id" ] || {
    printf 'unknown|persisted Paseo agent id mismatch\n'
    return 0
  }
  provider=$(jq -r '.Provider' <<< "$inspect")
  status=$(jq -r '.Status' <<< "$inspect")
  record_status=$(jq -r '.lastStatus // empty' <<< "$record")
  archived=$(jq -r '.Archived' <<< "$inspect")
  persistence=$(jq -r '.Capabilities.Persistence' <<< "$inspect")
  [ "$archived" = false ] || {
    printf 'unknown|target Paseo session is already archived\n'
    return 0
  }
  [ "$(jq -r '.archivedAt == null' <<< "$record")" = true ] || {
    printf 'unknown|persisted Paseo archive state disagrees with the daemon\n'
    return 0
  }
  [ "$provider" = "$owner_harness" ] || {
    printf 'unknown|Paseo provider does not match the verified lock-owner harness\n'
    return 0
  }
  case "$owner_harness" in
    claude|codex) ;;
    *)
      printf 'unsupported|only local Paseo-hosted Claude and Codex primary sessions are recoverable in v1\n'
      return 0
      ;;
  esac
  [ "$persistence" = true ] || {
    printf 'unsupported|Paseo reports no persistent provider session to restore\n'
    return 0
  }
  [ "$record_status" = "$status" ] || {
    printf 'unknown|persisted and live Paseo lifecycle states disagree\n'
    return 0
  }
  [ "$(jq -r '.provider // empty' <<< "$record")" = "$provider" ] || {
    printf 'unknown|persisted and live Paseo providers disagree\n'
    return 0
  }
  target_cwd=$(jq -r '.Cwd' <<< "$inspect")
  resolved_target_cwd=$(cd "$target_cwd" 2>/dev/null && pwd -P) || {
    printf 'unknown|Paseo target working directory cannot be resolved\n'
    return 0
  }
  resolved_root=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || {
    printf 'unknown|Firstmate root cannot be resolved\n'
    return 0
  }
  [ "$resolved_target_cwd" = "$resolved_root" ] \
    && [ "$(jq -r '.cwd // empty' <<< "$record")" = "$target_cwd" ] || {
      printf 'unknown|Paseo target is not bound to this Firstmate root\n'
      return 0
    }
  parent=$(jq -r '.ParentAgentId // empty' <<< "$inspect")
  [ -z "$parent" ] || {
    printf 'unsupported|target primary is itself attached to another Paseo agent\n'
    return 0
  }
  if target_has_attached_children "$agent_id"; then
    printf 'waiting-on-captain|target has attached child agents that archive could cascade\n'
    return 0
  else
    children_rc=$?
  fi
  [ "$children_rc" -eq 1 ] || {
    printf 'unknown|attached-child inventory could not be classified\n'
    return 0
  }
  pending=$(jq '.PendingPermissions | length' <<< "$inspect")
  requires_attention=$(jq -r '.requiresAttention // false' <<< "$record")
  attention_reason=$(jq -r '.attentionReason // empty' <<< "$record")
  if [ "$pending" -gt 0 ] || [ "$attention_reason" = permission ]; then
    printf 'waiting-on-captain|target has pending permission or captain action\n'
    return 0
  fi
  last_user=$(jq -r '.lastUserMessageAt // empty' <<< "$record")
  last_activity=$(jq -r '.lastActivityAt // empty' <<< "$record")
  if [ -n "$last_user" ]; then
    user_epoch=$(iso_epoch "$last_user" 2>/dev/null) || {
      printf 'unknown|provider has an unparseable structured input timestamp\n'
      return 0
    }
    if [ -z "$last_activity" ]; then
      unresolved=1
    else
      activity_epoch=$(iso_epoch "$last_activity" 2>/dev/null) || {
        printf 'unknown|provider has an unparseable structured activity timestamp\n'
        return 0
      }
      [ "$user_epoch" -le "$activity_epoch" ] || unresolved=1
    fi
  fi
  [ "$unresolved" -eq 0 ] || {
    printf 'waiting-on-captain|target owns unresolved structured input\n'
    return 0
  }
  quota_state=$(quota_classification "$provider" 2>/dev/null) || {
    printf 'unknown|fresh provider quota evidence is unavailable\n'
    return 0
  }
  if [ "$requires_attention" = true ]; then
    if [ "$attention_reason" = error ] && [ "$status" = idle ] && [ "$quota_state" = rate-limited ]; then
      printf 'paused-rate-limited|idle provider has a structured error plus exhausted fresh quota window\n'
    else
      printf 'waiting-on-captain|target has an unresolved structured attention marker\n'
    fi
    return 0
  fi
  case "$status" in
    idle)
      if [ "$quota_state" = rate-limited ]; then
        printf 'paused-rate-limited|idle provider has an exhausted fresh quota window\n'
      else
        printf 'idle|provider is structurally idle with no pending input, action, permission, or child\n'
      fi
      ;;
    running)
      [ -n "${activity_epoch:-}" ] \
        || activity_epoch=$(iso_epoch "$last_activity" 2>/dev/null) || {
        printf 'unknown|running provider has no parseable activity timestamp\n'
        return 0
      }
      now=$(date +%s)
      age=$(( now - activity_epoch ))
      if [ "$age" -ge "$FM_PRIMARY_WEDGE_SECS" ]; then
        printf 'wedged|provider is still running with no structured activity inside the wedge bound\n'
      else
        printf 'busy|provider has a live running turn\n'
      fi
      ;;
    *)
      printf 'unknown|provider lifecycle is neither safely idle nor a classifiable running turn\n'
      ;;
  esac
}

prove_lock_owner() {
  local agent_id=$1 owner_pid=$2 owner_harness=$3 process_agent descriptor descriptor_pid descriptor_harness
  local descriptor_manager descriptor_agent descriptor_identity current_identity current_identity_hash
  local provider_session list listed_id listed_session matches=0
  process_agent=$(fm_process_env_value "$owner_pid" PASEO_AGENT_ID 2>/dev/null || true)
  descriptor="$STATE/.lock.owner"
  if [ -e "$descriptor" ] || [ -L "$descriptor" ]; then
    [ -f "$descriptor" ] && [ ! -L "$descriptor" ] \
      || die "owner mismatch: state/.lock.owner is not a regular file"
    [ "$(fm_primary_owner_descriptor_value "$STATE" schema 2>/dev/null || true)" = "fm-primary-lock-owner.v1" ] \
      || die "owner mismatch: state/.lock.owner has an unsupported schema"
    descriptor_pid=$(fm_primary_owner_descriptor_value "$STATE" owner_pid 2>/dev/null || true)
    descriptor_identity=$(fm_primary_owner_descriptor_value "$STATE" owner_identity_sha256 2>/dev/null || true)
    descriptor_harness=$(fm_primary_owner_descriptor_value "$STATE" harness 2>/dev/null || true)
    descriptor_manager=$(fm_primary_owner_descriptor_value "$STATE" manager 2>/dev/null || true)
    descriptor_agent=$(fm_primary_owner_descriptor_value "$STATE" external_session_id 2>/dev/null || true)
    current_identity=$(fm_pid_identity "$owner_pid") \
      || die "owner mismatch: the live lock-owner process identity is unreadable"
    current_identity_hash=$(printf '%s' "$current_identity" | fm_primary_sha256_text) \
      || die "owner mismatch: the live lock-owner process identity cannot be hashed"
    [ "$descriptor_pid" = "$owner_pid" ] \
      && [ "$descriptor_identity" = "$current_identity_hash" ] \
      && [ "$descriptor_harness" = "$owner_harness" ] \
      && [ "$descriptor_manager" = paseo ] \
      && [ "$descriptor_agent" = "$agent_id" ] \
      || die "owner mismatch: state/.lock.owner does not bind the requested live Paseo owner"
    return 0
  fi
  [ "$process_agent" = "$agent_id" ] && return 0
  provider_session=$(fm_primary_provider_session_from_paseo_state "$agent_id" 2>/dev/null || true)
  fm_primary_atom_valid "$provider_session" \
    || die "owner mismatch: no descriptor or provider-session proof binds the requested Paseo agent"
  fm_process_command_has_atom "$owner_pid" "$provider_session" \
    || die "owner mismatch: the lock owner command does not contain the requested provider session"
  list=$(paseo agent ls --global --json 2>/dev/null) \
    || die "owner mismatch: visible Paseo sessions could not be checked for provider-session uniqueness"
  jq -e 'type == "array"' <<< "$list" >/dev/null \
    || die "owner mismatch: visible Paseo session data is not an array"
  while IFS= read -r listed_id; do
    fm_primary_atom_valid "$listed_id" \
      || die "owner mismatch: a visible Paseo session id is malformed"
    listed_session=$(fm_primary_provider_session_from_paseo_state "$listed_id" 2>/dev/null || true)
    [ "$listed_session" = "$provider_session" ] || continue
    matches=$(( matches + 1 ))
    [ "$listed_id" = "$agent_id" ] \
      || die "owner mismatch: provider session is shared by another visible Paseo agent"
  done < <(jq -r '.[] | .id // .Id // empty' <<< "$list")
  [ "$matches" -eq 1 ] \
    || die "owner mismatch: provider-session proof is not unique among visible Paseo agents"
}

process_tree_pids() {
  local root_pid=$1
  ps -axo pid=,ppid= 2>/dev/null | awk -v root="$root_pid" '
    {
      parent[$1] = $2
    }
    END {
      selected[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (pid in parent) {
          if (!selected[pid] && selected[parent[pid]]) {
            selected[pid] = 1
            changed = 1
          }
        }
      }
      for (pid in selected) {
        if (selected[pid]) {
          print pid
        }
      }
    }
  ' | sort -n
}

wait_tree_gone() {
  local pids=$1 deadline now pid any stat
  FM_PRIMARY_REMAINING_PIDS=
  deadline=$(( $(date +%s) + FM_PRIMARY_OWNER_EXIT_TIMEOUT ))
  while :; do
    any=0
    FM_PRIMARY_REMAINING_PIDS=
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if fm_process_pid_running "$pid"; then
        any=1
        stat=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
        FM_PRIMARY_REMAINING_PIDS="${FM_PRIMARY_REMAINING_PIDS}${FM_PRIMARY_REMAINING_PIDS:+,}${pid}:${stat:-unreadable}"
      fi
    done <<< "$pids"
    [ "$any" -eq 0 ] && return 0
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

remaining_pid_atoms() {
  local remaining=$1 token pid out=
  local -a tokens
  IFS=, read -r -a tokens <<< "$remaining"
  for token in "${tokens[@]}"; do
    pid=${token%%:*}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    out="${out}${out:+,}${pid}"
  done
  printf '%s\n' "$out"
}

receipt_prepare() {
  local agent_id=$1 owner_pid=$2 owner_harness=$3 provider=$4 classification=$5
  local provider_session fingerprint identity identity_hash receipt_stamp draft receipt_id
  mkdir -p "$HANDOFF_DIR" || return 1
  [ -d "$HANDOFF_DIR" ] && [ ! -L "$HANDOFF_DIR" ] || return 1
  fingerprint=$(fm_primary_home_fingerprint) || return 1
  identity=$(fm_pid_identity "$owner_pid") || return 1
  identity_hash=$(printf '%s' "$identity" | fm_primary_sha256_text) || return 1
  provider_session=$(fm_primary_provider_session_from_paseo_state "$agent_id" 2>/dev/null || true)
  receipt_stamp=$(date -u '+%Y%m%dT%H%M%SZ')
  umask 077
  draft=$(mktemp "$HANDOFF_DIR/.${receipt_stamp}-${agent_id}.XXXXXX") || return 1
  receipt_id=$(basename "$draft")
  receipt_id=${receipt_id#.}
  if ! {
    printf 'schema=fm-primary-session-handoff.v1\n'
    printf 'receipt_id=%s\n' "$receipt_id"
    printf 'home_fingerprint=%s\n' "$fingerprint"
    printf 'manager=paseo\n'
    printf 'external_session_id=%s\n' "$agent_id"
    printf 'provider=%s\n' "$provider"
    printf 'harness=%s\n' "$owner_harness"
    printf 'provider_session_id=%s\n' "$provider_session"
    printf 'old_owner_pid=%s\n' "$owner_pid"
    printf 'old_owner_identity_sha256=%s\n' "$identity_hash"
    printf 'classification=%s\n' "$classification"
    printf 'prepared_at=%s\n' "$(fm_primary_now_utc)"
    printf 'state=preparing\n'
  } > "$draft"; then
    rm -f "$draft"
    return 1
  fi
  printf '%s\n' "$draft"
}

receipt_publish() {
  local draft=$1 state=$2 at_key=$3 final receipt_id now
  now=$(fm_primary_now_utc) || return 1
  fm_primary_receipt_append_state "$draft" "$state" "$at_key" "$now" || return 1
  receipt_id=$(fm_primary_receipt_last_value "$draft" receipt_id) || return 1
  final="$HANDOFF_DIR/$receipt_id.receipt"
  [ ! -e "$final" ] && [ ! -L "$final" ] || return 1
  mv "$draft" "$final" || return 1
  printf '%s\n' "$final"
}

acquire_claim_lock() {
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$CLAIM_LOCK"
  CLAIM_LOCK_HELD=1
}

release_claim_lock() {
  if [ "${CLAIM_LOCK_HELD:-0}" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}

takeover() {
  local agent_id=$1 new_owner_pid owner_pid owner_harness classification reason inspect provider
  local tree draft archive_out post receipt new_lock_pid now remaining rc=0
  fm_primary_atom_valid "$agent_id" || die "invalid Paseo agent id"
  require_takeover_tools
  primary_scope_required
  [ -d "$STATE" ] || die "state directory is absent"
  new_owner_pid=$(fm_harness_ancestry_pid) || die "cannot resolve this new primary's verified harness ancestry"
  CLAIM_LOCK_HELD=0
  trap release_claim_lock EXIT
  trap 'exit 1' HUP INT TERM
  acquire_claim_lock
  [ -f "$LOCK" ] && [ ! -L "$LOCK" ] || die "takeover requires a regular existing session lock"
  owner_pid=$(cat "$LOCK" 2>/dev/null) || die "session lock is unreadable"
  case "$owner_pid" in ''|*[!0-9]*|1) die "session lock owner is malformed" ;; esac
  [ "$owner_pid" != "$new_owner_pid" ] || die "this primary already owns the session lock"
  fm_harness_pid_alive "$owner_pid" || die "requested takeover target is not a provably live verified lock owner"
  owner_harness=$(fm_harness_pid_kind "$owner_pid") || die "cannot classify the live lock-owner harness"
  prove_lock_owner "$agent_id" "$owner_pid" "$owner_harness"
  IFS='|' read -r classification reason <<< "$(classify_target "$owner_pid" "$agent_id" "$owner_harness")"
  case "$classification" in
    idle|paused-rate-limited) ;;
    *) die "takeover refused: $classification: $reason" ;;
  esac
  inspect=$(paseo_inspect "$agent_id") || die "Paseo inspection failed before suspension"
  provider=$(jq -r '.Provider' <<< "$inspect")
  tree=$(process_tree_pids "$owner_pid") || die "could not capture the lock-owner process tree"
  grep -qx "$owner_pid" <<< "$tree" || die "captured process tree omitted its owner"
  grep -qx "$new_owner_pid" <<< "$tree" \
    && die "takeover refused: the successor primary is inside the target provider process tree"
  draft=$(receipt_prepare "$agent_id" "$owner_pid" "$owner_harness" "$provider" "$classification") \
    || die "could not prepare a durable handoff receipt before suspension"
  if ! archive_out=$(paseo agent archive "$agent_id" --json 2>&1); then
    rm -f "$draft"
    die "Paseo soft archive failed: $archive_out"
  fi
  post=$(paseo_inspect "$agent_id" 2>/dev/null) || {
    receipt=$(receipt_publish "$draft" suspend-incomplete suspend_incomplete_at) || true
    die "Paseo archive returned success but the archived session could not be verified"
  }
  if [ "$(jq -r '.Archived' <<< "$post")" != true ]; then
    receipt=$(receipt_publish "$draft" suspend-incomplete suspend_incomplete_at) || true
    die "Paseo archive returned success but the target is not archived"
  fi
  if ! wait_tree_gone "$tree"; then
    remaining=$(remaining_pid_atoms "$FM_PRIMARY_REMAINING_PIDS")
    if [ -n "$remaining" ]; then
      printf 'remaining_pids=%s\n' "$remaining" >> "$draft" \
        || die "owner process tree remained alive and the remaining process receipt could not be recorded"
    else
      die "owner process tree remained alive and the remaining process receipt could not be recorded"
    fi
    receipt=$(receipt_publish "$draft" suspend-incomplete suspend_incomplete_at) \
      || die "owner process tree remained alive and the incomplete handoff receipt could not be published"
    die "owner process tree remained alive after soft archive ($FM_PRIMARY_REMAINING_PIDS); lock was left untouched; receipt: $receipt"
  fi
  receipt=$(receipt_publish "$draft" suspended suspended_at) \
    || die "provider was suspended but the durable handoff receipt could not be published"
  release_claim_lock
  if ! "$SCRIPT_DIR/fm-lock.sh"; then
    die "provider was suspended, but this primary lost or failed canonical stale-lock acquisition; receipt: $receipt"
  fi
  new_lock_pid=$(cat "$LOCK" 2>/dev/null || true)
  [ "$new_lock_pid" = "$new_owner_pid" ] \
    || die "canonical acquisition returned without the expected new owner; receipt: $receipt"
  now=$(fm_primary_now_utc)
  {
    printf 'taken_over_at=%s\n' "$now"
    printf 'successor_owner_pid=%s\n' "$new_owner_pid"
    printf 'state=active-successor\n'
  } >> "$receipt" || die "new primary owns the lock but receipt finalization failed: $receipt"
  printf 'primary-session: takeover complete: %s -> harness pid %s\n' "$agent_id" "$new_owner_pid"
  printf 'primary-session: receipt: %s\n' "$receipt"
  "$SCRIPT_DIR/fm-session-start.sh" || rc=$?
  [ "$rc" -eq 0 ] || die "lock transferred, but ordinary session start failed with exit $rc"
}

resolve_receipt() {
  local receipt_id=$1 candidate
  fm_primary_atom_valid "$receipt_id" || return 1
  candidate="$HANDOFF_DIR/$receipt_id"
  case "$candidate" in *.receipt) ;; *) candidate="${candidate}.receipt" ;; esac
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

restore() {
  local receipt_id=$1 receipt fingerprint receipt_home state agent_id manager harness provider inspect out
  local deadline post now lock_pid
  require_read_tools
  primary_scope_required
  receipt=$(resolve_receipt "$receipt_id") || die "receipt not found or invalid: $receipt_id"
  [ "$(fm_primary_receipt_last_value "$receipt" schema 2>/dev/null || true)" = "fm-primary-session-handoff.v1" ] \
    || die "receipt has an unsupported schema"
  fingerprint=$(fm_primary_home_fingerprint) || die "cannot fingerprint this Firstmate home"
  receipt_home=$(fm_primary_receipt_last_value "$receipt" home_fingerprint 2>/dev/null || true)
  [ "$receipt_home" = "$fingerprint" ] || die "receipt belongs to a different Firstmate home"
  state=$(fm_primary_receipt_last_value "$receipt" state 2>/dev/null || true)
  case "$state" in
    active-successor|suspended|suspend-incomplete|restore-failed) ;;
    *) die "receipt state '$state' is not eligible for restore" ;;
  esac
  manager=$(fm_primary_receipt_last_value "$receipt" manager 2>/dev/null || true)
  harness=$(fm_primary_receipt_last_value "$receipt" harness 2>/dev/null || true)
  provider=$(fm_primary_receipt_last_value "$receipt" provider 2>/dev/null || true)
  agent_id=$(fm_primary_receipt_last_value "$receipt" external_session_id 2>/dev/null || true)
  [ "$manager" = paseo ] || die "receipt manager '$manager' is unsupported"
  case "$harness:$provider" in
    claude:claude|codex:codex) ;;
    *) die "receipt provider/harness '$provider/$harness' is unsupported for enforced restoration" ;;
  esac
  fm_primary_atom_valid "$agent_id" || die "receipt external session id is invalid"
  CLAIM_LOCK_HELD=0
  trap release_claim_lock EXIT
  trap 'exit 1' HUP INT TERM
  acquire_claim_lock
  if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
    [ -f "$LOCK" ] && [ ! -L "$LOCK" ] || die "session lock is not a regular file"
    lock_pid=$(cat "$LOCK" 2>/dev/null) || die "session lock is unreadable"
    case "$lock_pid" in ''|*[!0-9]*|1) die "session lock owner is malformed" ;; esac
    if kill -0 "$lock_pid" 2>/dev/null; then
      die "restore refused: live pid $lock_pid still owns or ambiguously occupies the session lock"
    fi
  fi
  inspect=$(paseo_inspect "$agent_id" 2>/dev/null) || die "cannot inspect archived Paseo agent $agent_id"
  [ "$(jq -r '.Id' <<< "$inspect")" = "$agent_id" ] || die "Paseo resolved a different restore target"
  [ "$(jq -r '.Archived' <<< "$inspect")" = true ] || die "restore target is not archived"
  now=$(fm_primary_now_utc)
  fm_primary_receipt_append_state "$receipt" restore-requested restore_requested_at "$now" \
    || die "cannot record the restore request"
  if ! out=$(paseo agent reload "$agent_id" --json 2>&1); then
    now=$(fm_primary_now_utc)
    fm_primary_receipt_append_state "$receipt" restore-failed restore_failed_at "$now" || true
    die "Paseo reload failed: $out"
  fi
  deadline=$(( $(date +%s) + FM_PRIMARY_RELOAD_TIMEOUT ))
  while :; do
    post=$(paseo_inspect "$agent_id" 2>/dev/null || true)
    if [ -n "$post" ] && [ "$(jq -r '.Id // empty' <<< "$post" 2>/dev/null)" = "$agent_id" ] \
      && [ "$(jq -r '.Archived' <<< "$post" 2>/dev/null)" = false ]; then
      break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || {
      now=$(fm_primary_now_utc)
      fm_primary_receipt_append_state "$receipt" restore-failed restore_failed_at "$now" || true
      die "Paseo reload returned success but the session did not become visible"
    }
    sleep 0.1
  done
  printf 'reload_observed_at=%s\n' "$(fm_primary_now_utc)" >> "$receipt" \
    || die "reload succeeded but receipt observation could not be recorded"
  release_claim_lock
  printf 'primary-session: restore requested for %s\n' "$agent_id"
  printf 'primary-session: restored provider must complete the native session-start nudge and acquire the normal Firstmate lock before mutation\n'
  printf 'primary-session: receipt remains state=restore-requested until that lock acquisition is recorded: %s\n' "$receipt"
}

scan() {
  local format=${1:-table} list rows row agent_id inspect record pending attention reason parent provider status item
  require_read_tools
  list=$(paseo agent ls --global --json 2>/dev/null) || die "could not list local Paseo sessions"
  jq -e 'type == "array" and all(.[]; (.id | type) == "string")' <<< "$list" >/dev/null \
    || die "Paseo session inventory has an unsupported schema"
  rows=
  while IFS= read -r row; do
    agent_id=$(jq -r '.id' <<< "$row")
    inspect=$(paseo_inspect "$agent_id" 2>/dev/null) || die "could not inspect visible Paseo session $agent_id"
    [ "$(jq -r '.Archived' <<< "$inspect")" = false ] || continue
    record=$(paseo_agent_record "$agent_id" 2>/dev/null) || die "could not read structured Paseo state for $agent_id"
    pending=$(jq '.PendingPermissions | length' <<< "$inspect")
    attention=$(jq -r '.requiresAttention // false' <<< "$record")
    reason=$(jq -r '.attentionReason // empty' <<< "$record")
    if [ "$pending" -gt 0 ]; then
      reason=permission
    elif [ "$attention" != true ]; then
      continue
    fi
    case "$reason" in
      permission|finished|error) ;;
      needs_input) reason=needs-input ;;
      *) reason=attention ;;
    esac
    parent=$(jq -r '.ParentAgentId // empty' <<< "$inspect")
    provider=$(jq -r '.Provider' <<< "$inspect")
    status=$(jq -r '.Status' <<< "$inspect")
    item=$(jq -cn \
      --arg id "$agent_id" \
      --arg provider "$provider" \
      --arg status "$status" \
      --arg action "$reason" \
      --argjson pending "$pending" \
      --arg parent "$parent" \
      '{external_session_id:$id,provider:$provider,status:$status,action:$action,pending_permissions:$pending,parent_agent_id:(if $parent == "" then null else $parent end)}')
    rows="${rows}${item}"$'\n'
  done < <(jq -c '.[]' <<< "$list")
  if [ "$format" = json ]; then
    printf '%s' "$rows" | jq -s '.'
    return
  fi
  if [ -z "$rows" ]; then
    printf 'primary-session: no visible Paseo sessions await permission or captain action\n'
    return
  fi
  printf 'EXTERNAL_SESSION_ID\tPROVIDER\tSTATUS\tACTION\tPENDING_PERMISSIONS\tPARENT_AGENT_ID\n'
  printf '%s' "$rows" | jq -r '[.external_session_id,.provider,.status,.action,(.pending_permissions|tostring),(.parent_agent_id // "-")] | @tsv'
}

command=${1:-}
case "$command" in
  scan)
    case "${2:-}" in
      '') scan table ;;
      --json) scan json ;;
      *) die "unknown scan option: ${2:-}" ;;
    esac
    ;;
  takeover)
    [ "$#" -eq 2 ] || die "usage: fm-primary-session.sh takeover <paseo-agent-id>"
    takeover "$2"
    ;;
  restore)
    [ "$#" -eq 2 ] || die "usage: fm-primary-session.sh restore <receipt-id>"
    restore "$2"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
