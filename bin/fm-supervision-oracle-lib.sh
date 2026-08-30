#!/usr/bin/env bash
# fm-supervision-oracle-lib.sh - executable invariants for synthetic Firstmate homes.
#
# Sourced by bin/fm-supervision-oracle.sh and the stress-test oracle suite.
# Every check is read-only over the target home and refuses live-fleet paths.
#
# Invariants:
#   work_preserved        uncommitted changes and unpushed commits survive recovery
#   no_orphans            live endpoints have metadata; in-flight metadata has live endpoint or terminal outcome
#   liveness_honest       recorded liveness verdicts match ground-truth endpoint state
#   wake_queue_converged  drain then ack leaves no durable wake; replay is idempotent
#   state_matches_reality task records, metadata, worktrees, and endpoints agree

FM_ORACLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ORACLE_DEFAULT_ROOT="$(cd "$FM_ORACLE_LIB_DIR/.." && pwd)"
FM_ORACLE_HOME="${FM_ORACLE_HOME:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ORACLE_DEFAULT_ROOT}}}"
FM_ORACLE_STATE="${FM_ORACLE_STATE:-${FM_STATE_OVERRIDE:-$FM_ORACLE_HOME/state}}"
FM_ORACLE_SNAPSHOT="${FM_ORACLE_SNAPSHOT:-$FM_ORACLE_STATE/.supervision-oracle-snapshot.tsv}"
FM_ORACLE_LIVENESS="${FM_ORACLE_LIVENESS:-$FM_ORACLE_STATE/.supervision-oracle-liveness.tsv}"
FM_ORACLE_ENDPOINTS="${FM_ORACLE_ENDPOINTS:-$FM_ORACLE_STATE/.supervision-oracle-endpoints.tsv}"
FM_ORACLE_CREW_STATE="${FM_ORACLE_CREW_STATE:-$FM_ORACLE_LIB_DIR/fm-crew-state.sh}"
FM_ORACLE_WAKE_DRAIN="${FM_ORACLE_WAKE_DRAIN:-$FM_ORACLE_LIB_DIR/fm-wake-drain.sh}"

FM_ORACLE_LIVE_FLEET_PREFIXES=(
  /Users/pedromuller/dev/firstmate/state
  /Users/pedromuller/.treehouse
)

fm_oracle_die() {
  printf 'fm-supervision-oracle: %s\n' "$*" >&2
  return 2
}

fm_oracle_realpath() {
  local path=$1
  cd "$path" 2>/dev/null && pwd -P
}

fm_oracle_assert_synthetic_home() {
  local home resolved prefix
  home=$1
  if [ -z "$home" ]; then
    fm_oracle_die "home path is required"
    return 2
  fi
  resolved=$(fm_oracle_realpath "$home") || {
    fm_oracle_die "home is not reachable: $home"
    return 2
  }
  for prefix in "${FM_ORACLE_LIVE_FLEET_PREFIXES[@]}"; do
    case "$resolved" in
      "$prefix"|"$prefix"/*)
        fm_oracle_die "refusing live fleet path: $resolved"
        return 2
        ;;
    esac
  done
  if [ ! -f "$resolved/.fm-synthetic-home" ]; then
    fm_oracle_die "refusing non-synthetic home (missing .fm-synthetic-home): $resolved"
    return 2
  fi
  printf '%s\n' "$resolved"
}

fm_oracle_meta_value() {
  local file=$1 key=$2
  grep "^$key=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_oracle_status_last_line() {
  local log=$1
  [ -f "$log" ] || return 1
  grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -1
}

fm_oracle_status_verb() {
  local line=$1
  printf '%s' "$line" | sed -n 's/^\([^:[:space:]]*\).*/\1/p'
}

fm_oracle_task_terminal() {
  local id=$1 meta log line verb
  meta="$FM_ORACLE_STATE/$id.meta"
  [ -f "$meta" ] || return 0
  if [ -n "$(fm_oracle_meta_value "$meta" terminal)" ]; then
    return 0
  fi
  log="$FM_ORACLE_STATE/$id.status"
  line=$(fm_oracle_status_last_line "$log" || true)
  [ -n "$line" ] || return 1
  verb=$(fm_oracle_status_verb "$line")
  case "$verb" in
    done|failed) return 0 ;;
    *) return 1 ;;
  esac
}

fm_oracle_task_inflight() {
  local id=$1 meta line verb
  meta="$FM_ORACLE_STATE/$id.meta"
  [ -f "$meta" ] || return 1
  fm_oracle_task_terminal "$id" && return 1
  log="$FM_ORACLE_STATE/$id.status"
  line=$(fm_oracle_status_last_line "$log" || true)
  [ -n "$line" ] || return 0
  verb=$(fm_oracle_status_verb "$line")
  case "$verb" in
    working|paused) return 0 ;;
    done|failed|needs-decision|blocked) return 1 ;;
    *) return 0 ;;
  esac
}

fm_oracle_work_fingerprint() {
  local wt=$1 head dirty unpushed
  [ -d "$wt" ] || { printf 'missing\n'; return; }
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || head=unborn
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | shasum -a 256 2>/dev/null | awk '{print $1}')
  [ -n "$dirty" ] || dirty=empty
  unpushed=$(git -C "$wt" log --format=%H HEAD --not --remotes -- 2>/dev/null | shasum -a 256 2>/dev/null | awk '{print $1}')
  [ -n "$unpushed" ] || unpushed=empty
  printf 'head=%s dirty=%s unpushed=%s\n' "$head" "$dirty" "$unpushed"
}

fm_oracle_snapshot_write() {
  local meta id wt fp
  : > "$FM_ORACLE_SNAPSHOT"
  for meta in "$FM_ORACLE_STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    wt=$(fm_oracle_meta_value "$meta" worktree)
    [ -n "$wt" ] || continue
    fp=$(fm_oracle_work_fingerprint "$wt")
    printf 'work\t%s\t%s\n' "$id" "$fp" >> "$FM_ORACLE_SNAPSHOT"
  done
}

fm_oracle_liveness_set() { # <id> <live|absent|unknown>
  local id=$1 verdict=$2 tmp
  mkdir -p "$(dirname "$FM_ORACLE_LIVENESS")"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-oracle-liveness.XXXXXX") || return 1
  if [ -f "$FM_ORACLE_LIVENESS" ]; then
    grep -v "^${id}	" "$FM_ORACLE_LIVENESS" > "$tmp" || true
  fi
  printf '%s	%s\n' "$id" "$verdict" >> "$tmp"
  mv "$tmp" "$FM_ORACLE_LIVENESS"
}

fm_oracle_endpoint_set() { # <id> <alive|dead>
  local id=$1 alive=$2 tmp
  mkdir -p "$(dirname "$FM_ORACLE_ENDPOINTS")"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-oracle-endpoints.XXXXXX") || return 1
  if [ -f "$FM_ORACLE_ENDPOINTS" ]; then
    grep -v "^${id}	" "$FM_ORACLE_ENDPOINTS" > "$tmp" || true
  fi
  printf '%s	%s\n' "$id" "$alive" >> "$tmp"
  mv "$tmp" "$FM_ORACLE_ENDPOINTS"
}

fm_oracle_emit_violation() {
  printf 'VIOLATION: %s\n' "$1"
}

fm_oracle_check_work_preserved() {
  local line id fp stored wt meta violations=0
  [ -f "$FM_ORACLE_SNAPSHOT" ] || return 0
  while IFS=$'\t' read -r kind id stored; do
    [ "$kind" = work ] || continue
    meta="$FM_ORACLE_STATE/$id.meta"
    wt=$(fm_oracle_meta_value "$meta" worktree)
    fp=$(fm_oracle_work_fingerprint "$wt")
    if [ "$fp" != "$stored" ]; then
      fm_oracle_emit_violation "work_preserved: task $id worktree changed (was '$stored', now '$fp')"
      violations=$((violations + 1))
    fi
  done < "$FM_ORACLE_SNAPSHOT"
  [ "$violations" -eq 0 ]
}

fm_oracle_check_no_orphans() {
  local meta id alive violations=0
  if [ -f "$FM_ORACLE_ENDPOINTS" ]; then
    while IFS=$'\t' read -r id alive; do
      [ -n "$id" ] || continue
      [ "$alive" = alive ] || continue
      [ -f "$FM_ORACLE_STATE/$id.meta" ] || {
        fm_oracle_emit_violation "no_orphans: live endpoint $id has no metadata"
        violations=$((violations + 1))
      }
    done < "$FM_ORACLE_ENDPOINTS"
  fi
  for meta in "$FM_ORACLE_STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_oracle_task_inflight "$id" || continue
    alive=
    if [ -f "$FM_ORACLE_ENDPOINTS" ]; then
      alive=$(awk -F '\t' -v id="$id" '$1 == id { print $2; exit }' "$FM_ORACLE_ENDPOINTS")
    fi
    case "$alive" in
      alive) continue ;;
    esac
  fm_oracle_emit_violation "no_orphans: in-flight task $id has no live endpoint and no terminal outcome"
    violations=$((violations + 1))
  done
  [ "$violations" -eq 0 ]
}

fm_oracle_liveness_expected() {
  local id=$1
  if [ -f "$FM_ORACLE_LIVENESS" ]; then
    awk -F '\t' -v id="$id" '$1 == id { print $2; exit }' "$FM_ORACLE_LIVENESS"
  fi
}

fm_oracle_liveness_actual() {
  local id=$1 line
  line=$(FM_HOME="$FM_ORACLE_HOME" FM_STATE_OVERRIDE="$FM_ORACLE_STATE" \
    "$FM_ORACLE_CREW_STATE" --worker-liveness "$id" 2>/dev/null) || line='liveness: unknown · source: none'
  case "$line" in
    "liveness: live"*) printf 'live\n' ;;
    "liveness: absent"*) printf 'absent\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

fm_oracle_check_liveness_honest() {
  local id expected actual violations=0
  if [ ! -f "$FM_ORACLE_LIVENESS" ]; then
    return 0
  fi
  while IFS=$'\t' read -r id expected; do
    [ -n "$id" ] || continue
    actual=$(fm_oracle_liveness_actual "$id")
    case "$expected" in
      live)
        [ "$actual" = live ] || {
          fm_oracle_emit_violation "liveness_honest: task $id is alive but reported $actual"
          violations=$((violations + 1))
        }
        ;;
      absent)
        [ "$actual" = absent ] || {
          fm_oracle_emit_violation "liveness_honest: task $id is dead but reported $actual"
          violations=$((violations + 1))
        }
        ;;
      unknown)
        [ "$actual" = unknown ] || {
          fm_oracle_emit_violation "liveness_honest: task $id has ambiguous evidence but reported $actual"
          violations=$((violations + 1))
        }
        ;;
    esac
  done < "$FM_ORACLE_LIVENESS"
  [ "$violations" -eq 0 ]
}

fm_oracle_wake_drain_once() {
  local out err rc
  out=$(mktemp "${TMPDIR:-/tmp}/fm-oracle-drain.out.XXXXXX") || return 1
  err=$(mktemp "${TMPDIR:-/tmp}/fm-oracle-drain.err.XXXXXX") || { rm -f "$out"; return 1; }
  FM_HOME="$FM_ORACLE_HOME" FM_STATE_OVERRIDE="$FM_ORACLE_STATE" \
    "$FM_ORACLE_WAKE_DRAIN" >"$out" 2>"$err"
  rc=$?
  printf '%s\n' "$out"
  if [ -s "$err" ]; then
    cat "$err" >&2
  fi
  if grep -q '^WAKE_ACK_REQUIRED:' "$err" 2>/dev/null; then
    local sequence generation
    sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
    generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
    if [ -n "$sequence" ] && [ -n "$generation" ]; then
      FM_HOME="$FM_ORACLE_HOME" FM_STATE_OVERRIDE="$FM_ORACLE_STATE" \
        "$FM_ORACLE_WAKE_DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null
    fi
  fi
  rm -f "$out" "$err"
  return "$rc"
}

fm_oracle_check_wake_queue_converged() {
  fm_oracle_wake_drain_once >/dev/null || return 1
  if [ -f "$FM_ORACLE_STATE/.wake-queue" ] && [ -s "$FM_ORACLE_STATE/.wake-queue" ]; then
    fm_oracle_emit_violation "wake_queue_converged: durable wake rows remain after drain and ack"
    return 1
  fi
  fm_oracle_wake_drain_once >/dev/null || return 1
  if [ -f "$FM_ORACLE_STATE/.wake-queue" ] && [ -s "$FM_ORACLE_STATE/.wake-queue" ]; then
    fm_oracle_emit_violation "wake_queue_converged: replay left durable wake rows behind"
    return 1
  fi
  return 0
}

fm_oracle_check_state_matches_reality() {
  local meta id wt endpoint_task_id violations=0 alive
  local abs pairs=''
  for meta in "$FM_ORACLE_STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    wt=$(fm_oracle_meta_value "$meta" worktree)
  endpoint_task_id=$(fm_oracle_meta_value "$meta" endpoint_task_id)
    [ -z "$endpoint_task_id" ] || [ "$endpoint_task_id" = "$id" ] || {
      fm_oracle_emit_violation "state_matches_reality: task $id metadata endpoint_task_id=$endpoint_task_id"
      violations=$((violations + 1))
    }
    if [ -n "$wt" ]; then
      [ -d "$wt" ] || {
        fm_oracle_emit_violation "state_matches_reality: task $id worktree missing at $wt"
        violations=$((violations + 1))
      }
      if [ -d "$wt" ]; then
        abs=$(CDPATH='' cd -- "$wt" && pwd -P 2>/dev/null) || abs=$wt
        pairs="${pairs}${abs}"$'\t'"${id}"$'\n'
      fi
    fi
    if [ -f "$FM_ORACLE_ENDPOINTS" ]; then
      alive=$(awk -F '\t' -v id="$id" '$1 == id { print $2; exit }' "$FM_ORACLE_ENDPOINTS")
      case "$alive" in
        alive)
          window=$(fm_oracle_meta_value "$meta" window)
          [ -n "$window" ] || {
            fm_oracle_emit_violation "state_matches_reality: live task $id has no recorded endpoint window"
            violations=$((violations + 1))
          }
          ;;
      esac
    fi
  done
  if [ -n "$pairs" ]; then
    if duplicates=$(printf '%s' "$pairs" | cut -f1 | sort | uniq -d | head -1) && [ -n "$duplicates" ]; then
      fm_oracle_emit_violation "state_matches_reality: duplicate worktree claim for $duplicates"
      violations=$((violations + 1))
    fi
  fi
  [ "$violations" -eq 0 ]
}

fm_oracle_check_all() {
  local rc=0
  fm_oracle_check_work_preserved || rc=1
  fm_oracle_check_no_orphans || rc=1
  fm_oracle_check_liveness_honest || rc=1
  fm_oracle_check_wake_queue_converged || rc=1
  fm_oracle_check_state_matches_reality || rc=1
  return "$rc"
}
