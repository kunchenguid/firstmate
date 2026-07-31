#!/usr/bin/env bash
# Own the exact mechanics for Firstmate's no-mistakes readiness record and
# presentation-only Herdr attach monitor.
#
# Usage:
#   fm-no-mistakes-ready.sh init <task-id>
#   fm-no-mistakes-ready.sh approve <task-id> <exact-head> <reviewed-evidence-sha256>
#   fm-no-mistakes-ready.sh check <task-id>
#   fm-no-mistakes-ready.sh monitor-reconcile <task-id>
#   fm-no-mistakes-ready.sh monitor-clear-attempt <task-id> <attempt-token>
#
# `init` creates data/<task-id>/no-mistakes-readiness.tsv without overwriting an
# existing record.
# The record is tab-separated with exactly three fields per row:
#
#   key<TAB>verdict-or-value<TAB>evidence
#
# The fixed version 1 keys are version, head, intent_trace, self_audit,
# project_analysis, spec_kit, focused_tests, full_checks,
# implementation_complete, decisions, design_grounding, runtime_grounding,
# and maestro.
# Replace every `pending` verdict and placeholder evidence, then run `check`.
# After reviewing every evidence axis, the lock-owning Firstmate session alone
# runs `approve` with the exact implementation HEAD and SHA-256 captured from
# the record bytes it reviewed. The durable approval binds both that HEAD and
# the reviewed record bytes. Worker evidence without this approval cannot be
# ready.
# `check` also verifies the exact fm/<task-id> branch, clean committed worktree,
# record-to-HEAD and approval binding, no-mistakes ship metadata, and Spec Kit applicability.
# It prints `READY`, `NOT_READY`, or `ERROR` and exits 0, 1, or 2 respectively.
#
# The lock-owning Firstmate session alone runs `monitor-reconcile` and
# `monitor-clear-attempt`. Reconciliation reads the task's exact endpoint
# metadata and the current-branch AXI status.
# On Herdr it binds one state/<task-id>.no-mistakes-monitor journal to the exact
# run, session, workspace, tab, pane, canonical executable, and submitted head, then runs only
# `no-mistakes attach --run <id>` in a new `--no-focus` tab beside the worker.
# Repeated calls reuse that exact pane.
# A terminal run retires only the journal-bound pane, and only after exact
# process, topology, focus, and gone-state checks.
# A missing bound pane may be recreated only after it is positively absent.
# An ambiguous or repurposed pane is preserved and blocks duplicate creation.
# A create call whose response is lost leaves a version 0 attempt journal with
# an exact random token, session, workspace, and label.
# Firstmate must inspect that exact location, preserve or retire any resulting
# presentation pane in Herdr's UI, and only then pass the journal's token to
# `monitor-clear-attempt`.
# That recovery command removes only the attempt journal and never discovers,
# closes, sends input to, or otherwise mutates a pane.
# Other runtime backends print `not-applicable` and are not mutated.
# The attach pane is presentation only: this helper never calls `axi run`,
# `axi respond`, sync, abort, rerun, push, or merge.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fm_nm_error() {
  printf 'ERROR: %s\n' "$*" >&2
  return 2
}

fm_nm_task_load() { # <task-id>
  local id=$1
  fm_task_id_creation_valid "$id" || {
    fm_nm_error "invalid task id '$id'"
    return 2
  }
  FM_NM_ID=$id
  FM_NM_META="$STATE/$id.meta"
  fm_backend_validate_task_endpoint "$FM_NM_META" "$id" || return 2
  FM_NM_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  FM_NM_WORKTREE=$(fm_meta_get "$FM_NM_META" worktree)
  FM_NM_KIND=$(fm_meta_get "$FM_NM_META" kind)
  FM_NM_MODE=$(fm_meta_get "$FM_NM_META" mode)
  [ -d "$FM_NM_WORKTREE" ] && [ ! -L "$FM_NM_WORKTREE" ] || {
    fm_nm_error "task $id has no regular worktree at $FM_NM_WORKTREE"
    return 2
  }
  FM_NM_WORKTREE=$(cd "$FM_NM_WORKTREE" 2>/dev/null && pwd -P) || {
    fm_nm_error "task $id worktree cannot be resolved"
    return 2
  }
  return 0
}

fm_nm_record_path() {
  printf '%s/%s/no-mistakes-readiness.tsv' "$DATA" "$FM_NM_ID"
}

fm_nm_approval_path() {
  printf '%s/%s/no-mistakes-readiness.approval' "$DATA" "$FM_NM_ID"
}

fm_nm_approval_load() { # <approval>
  local approval=$1 key line_count
  [ -f "$approval" ] && [ ! -L "$approval" ] || return 3
  for key in version authority task head evidence_sha256; do
    [ "$(grep -c "^$key=" "$approval" 2>/dev/null || true)" -eq 1 ] || return 2
  done
  line_count=$(awk 'END { print NR + 0 }' "$approval")
  [ "$line_count" -eq 5 ] || return 2
  FM_NM_A_VERSION=$(fm_meta_get "$approval" version)
  FM_NM_A_AUTHORITY=$(fm_meta_get "$approval" authority)
  FM_NM_A_TASK=$(fm_meta_get "$approval" task)
  FM_NM_A_HEAD=$(fm_meta_get "$approval" head)
  FM_NM_A_EVIDENCE_SHA256=$(fm_meta_get "$approval" evidence_sha256)
  [ "$FM_NM_A_VERSION" = 1 ] && [ "$FM_NM_A_AUTHORITY" = firstmate ] \
    && [ "$FM_NM_A_TASK" = "$FM_NM_ID" ] || return 2
  case "$FM_NM_A_HEAD" in ''|*[!0-9a-f]*) return 2 ;; esac
  [ "${#FM_NM_A_EVIDENCE_SHA256}" -eq 64 ] || return 2
  case "$FM_NM_A_EVIDENCE_SHA256" in *[!0-9a-f]*) return 2 ;; esac
}

fm_nm_init() { # <task-id>
  local id=$1 record dir tmp head
  fm_nm_task_load "$id" || return $?
  record=$(fm_nm_record_path)
  dir=${record%/*}
  [ ! -e "$record" ] && [ ! -L "$record" ] || {
    fm_nm_error "readiness record already exists at $record"
    return 2
  }
  head=$(git -C "$FM_NM_WORKTREE" rev-parse HEAD 2>/dev/null) || {
    fm_nm_error "cannot resolve task $id HEAD"
    return 2
  }
  mkdir -p "$dir" || return 2
  tmp=$(mktemp "$dir/.no-mistakes-readiness.XXXXXX") || return 2
  chmod 600 "$tmp" || { rm -f "$tmp"; return 2; }
  {
    printf 'version\t1\tFirstmate no-mistakes readiness record\n'
    printf 'head\t%s\tExact implementation commit reviewed by this record\n' "$head"
    printf 'intent_trace\tpending\treplace with accepted-intent to implementation and evidence trace\n'
    printf 'self_audit\tpending\treplace with implementation self-audit evidence\n'
    printf 'project_analysis\tpending\treplace with project-native analysis evidence or not applicable because <specific inspected reason>\n'
    printf 'spec_kit\tpending\treplace with current Spec Kit gate evidence or not applicable because <specific inspected reason>\n'
    printf 'focused_tests\tpending\treplace with focused test commands and passing results\n'
    printf 'full_checks\tpending\treplace with relevant full-check commands and passing results\n'
    printf 'implementation_complete\tpending\treplace with evidence that no accepted behavior remains incomplete\n'
    printf 'decisions\tpending\treplace with evidence that no unresolved decision remains\n'
    printf 'design_grounding\tpending\treplace with applicable design-source evidence or not applicable because <specific inspected reason>\n'
    printf 'runtime_grounding\tpending\treplace with applicable real-flow evidence or not applicable because <specific inspected reason>\n'
    printf 'maestro\tpending\treplace with applicable NSM emulator evidence or not applicable because <specific inspected reason>\n'
  } > "$tmp"
  mv "$tmp" "$record" || { rm -f "$tmp"; return 2; }
  printf 'initialized: %s\n' "$record"
}

fm_nm_record_field() { # <record> <key> <field-number>
  awk -F '\t' -v key="$2" -v field="$3" '$1 == key { print $field }' "$1"
}

fm_nm_record_valid_shape() { # <record>
  awk -F '\t' '
    BEGIN {
      split("version head intent_trace self_audit project_analysis spec_kit focused_tests full_checks implementation_complete decisions design_grounding runtime_grounding maestro", allowed, " ")
      for (i in allowed) valid[allowed[i]] = 1
    }
    NF != 3 { bad = 1 }
    !($1 in valid) { bad = 1 }
    { seen[$1]++ }
    END {
      for (key in valid) if (seen[key] != 1) bad = 1
      exit bad ? 1 : 0
    }
  ' "$1"
}

fm_nm_spec_kit_present() {
  [ -d "$FM_NM_WORKTREE/.specify" ] && return 0
  [ -d "$FM_NM_WORKTREE/specs" ] || return 1
  find "$FM_NM_WORKTREE/specs" -mindepth 2 -maxdepth 3 \
    \( -name spec.md -o -name tasks.md -o -type d -name checklists \) \
    -print -quit 2>/dev/null | grep -q .
}

fm_nm_evidence_is_concrete() { # <verdict> <evidence>
  local verdict=$1 evidence=$2 normalized
  [ "${#evidence}" -ge 24 ] || return 1
  normalized=$(printf '%s' "$evidence" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[.!]*$//')
  case "$normalized" in
    done|looks\ good|not\ applicable|n/a|none|pass|passed|complete|completed|clear|yes|no|all\ good)
      return 1
      ;;
  esac
  if [ "$verdict" = not-applicable ]; then
    case "$normalized" in
      'not applicable because '*|'not-applicable because '*) ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

fm_nm_validate_readiness() { # <task-id> <require-approval> [record-snapshot]
  local id=$1 require_approval=$2 record=${3:-} approval branch head record_head axis verdict evidence
  local worktree_status evidence_sha256 approval_status failures=0
  fm_nm_task_load "$id" || return $?
  [ -n "$record" ] || record=$(fm_nm_record_path)
  if [ ! -f "$record" ] || [ -L "$record" ]; then
    printf "NOT_READY: task %s has no regular readiness record; run \`%s init %s\`\n" "$id" "$0" "$id"
    return 1
  fi
  if ! fm_nm_record_valid_shape "$record"; then
    fm_nm_error "malformed readiness record at $record"
    return 2
  fi
  if [ "$FM_NM_KIND" != ship ] || [ "$FM_NM_MODE" != no-mistakes ]; then
    fm_nm_error "task $id is kind=${FM_NM_KIND:-missing} mode=${FM_NM_MODE:-missing}, not a no-mistakes ship"
    return 2
  fi
  branch=$(git -C "$FM_NM_WORKTREE" branch --show-current 2>/dev/null) || branch=
  head=$(git -C "$FM_NM_WORKTREE" rev-parse HEAD 2>/dev/null) || head=
  record_head=$(fm_nm_record_field "$record" head 2)
  if [ "$branch" != "fm/$id" ]; then
    printf 'NOT_READY: expected branch fm/%s, found %s\n' "$id" "${branch:-detached}"
    failures=$((failures + 1))
  fi
  if [ -z "$head" ] || [ "$record_head" != "$head" ]; then
    printf 'NOT_READY: readiness record head %s does not match worktree HEAD %s\n' "${record_head:-missing}" "${head:-missing}"
    failures=$((failures + 1))
  fi
  if ! worktree_status=$(git -C "$FM_NM_WORKTREE" status --porcelain 2>/dev/null); then
    fm_nm_error "cannot determine whether task $id worktree is clean"
    return 2
  fi
  if [ -n "$worktree_status" ]; then
    printf 'NOT_READY: worktree is not clean and committed\n'
    failures=$((failures + 1))
  fi
  if [ "$(fm_nm_record_field "$record" version 2)" != 1 ]; then
    fm_nm_error "unsupported readiness record version"
    return 2
  fi
  for axis in intent_trace self_audit focused_tests full_checks implementation_complete; do
    verdict=$(fm_nm_record_field "$record" "$axis" 2)
    if [ "$verdict" != pass ]; then
      printf 'NOT_READY: %s must be pass, found %s\n' "$axis" "${verdict:-missing}"
      failures=$((failures + 1))
    fi
  done
  verdict=$(fm_nm_record_field "$record" decisions 2)
  if [ "$verdict" != clear ]; then
    printf 'NOT_READY: decisions must be clear, found %s\n' "${verdict:-missing}"
    failures=$((failures + 1))
  fi
  for axis in project_analysis spec_kit design_grounding runtime_grounding maestro; do
    verdict=$(fm_nm_record_field "$record" "$axis" 2)
    case "$verdict" in
      pass|not-applicable) ;;
      *)
        printf 'NOT_READY: %s must be pass or not-applicable, found %s\n' "$axis" "${verdict:-missing}"
        failures=$((failures + 1))
        ;;
    esac
  done
  verdict=$(fm_nm_record_field "$record" spec_kit 2)
  if fm_nm_spec_kit_present && [ "$verdict" != pass ]; then
    printf 'NOT_READY: Spec Kit markers are present, so spec_kit cannot be not-applicable\n'
    failures=$((failures + 1))
  fi
  for axis in intent_trace self_audit project_analysis spec_kit focused_tests full_checks implementation_complete decisions design_grounding runtime_grounding maestro; do
    verdict=$(fm_nm_record_field "$record" "$axis" 2)
    evidence=$(fm_nm_record_field "$record" "$axis" 3)
    if ! fm_nm_evidence_is_concrete "$verdict" "$evidence"; then
      printf 'NOT_READY: %s evidence must name a concrete command, artifact, result, trace, or specific non-applicability reason\n' "$axis"
      failures=$((failures + 1))
    fi
  done
  if [ "$require_approval" -eq 1 ]; then
    approval=$(fm_nm_approval_path)
    if [ ! -e "$approval" ] && [ ! -L "$approval" ]; then
      approval_status=3
    else
      fm_session_lock_owned_by_self "$STATE" || {
        fm_nm_error "semantic approval can be validated only by the lock-owning Firstmate session"
        return 2
      }
      fm_nm_approval_load "$approval" && approval_status=0 || approval_status=$?
    fi
    case "$approval_status" in
      0)
        evidence_sha256=$(fm_pr_sha256 "$record") || {
          fm_nm_error "cannot hash readiness evidence for approval validation"
          return 2
        }
        if [ "$FM_NM_A_HEAD" != "$head" ]; then
          printf 'NOT_READY: Firstmate approval head %s does not match worktree HEAD %s\n' "$FM_NM_A_HEAD" "${head:-missing}"
          failures=$((failures + 1))
        fi
        if [ "$FM_NM_A_EVIDENCE_SHA256" != "$evidence_sha256" ]; then
          printf 'NOT_READY: readiness evidence changed after Firstmate semantic approval\n'
          failures=$((failures + 1))
        fi
        ;;
      3)
        printf 'NOT_READY: exact-HEAD Firstmate semantic approval is missing\n'
        failures=$((failures + 1))
        ;;
      *)
        fm_nm_error "malformed Firstmate approval at $approval"
        return 2
        ;;
    esac
  fi
  if [ "$failures" -ne 0 ]; then
    printf 'NOT_READY: %s readiness requirement(s) remain\n' "$failures"
    return 1
  fi
  FM_NM_VALIDATED_RECORD=$record
  FM_NM_VALIDATED_HEAD=$head
  return 0
}

fm_nm_check() { # <task-id>
  local id=$1
  fm_nm_validate_readiness "$id" 1 || return $?
  printf 'READY: task %s at %s; evidence %s\n' "$id" "$FM_NM_VALIDATED_HEAD" "$FM_NM_VALIDATED_RECORD"
}

fm_nm_approve() { # <task-id> <exact-head> <reviewed-evidence-sha256>
  local id=$1 exact_head=$2 reviewed_evidence_sha256=$3 record approval dir snapshot tmp
  local snapshot_sha256 live_sha256 validated_head rc
  fm_session_lock_owned_by_self "$STATE" || {
    fm_nm_error "semantic approval can be published only by the lock-owning Firstmate session"
    return 2
  }
  [ "${#reviewed_evidence_sha256}" -eq 64 ] || {
    fm_nm_error "reviewed evidence SHA-256 must be 64 lowercase hexadecimal characters"
    return 2
  }
  case "$reviewed_evidence_sha256" in
    *[!0-9a-f]*)
      fm_nm_error "reviewed evidence SHA-256 must be 64 lowercase hexadecimal characters"
      return 2
      ;;
  esac
  fm_nm_task_load "$id" || return $?
  record=$(fm_nm_record_path)
  [ -f "$record" ] && [ ! -L "$record" ] || {
    fm_nm_error "readiness record is not a regular file at $record"
    return 2
  }
  dir=${record%/*}
  snapshot=$(mktemp "$dir/.no-mistakes-reviewed-evidence.XXXXXX") || return 2
  chmod 600 "$snapshot" || { rm -f "$snapshot"; return 2; }
  cp "$record" "$snapshot" || { rm -f "$snapshot"; return 2; }
  snapshot_sha256=$(fm_pr_sha256 "$snapshot") || {
    rm -f "$snapshot"
    fm_nm_error "cannot hash reviewed readiness evidence snapshot"
    return 2
  }
  if [ "$snapshot_sha256" != "$reviewed_evidence_sha256" ]; then
    rm -f "$snapshot"
    fm_nm_error "current readiness record does not match the reviewed evidence SHA-256"
    return 2
  fi
  if fm_nm_validate_readiness "$id" 0 "$snapshot"; then
    validated_head=$FM_NM_VALIDATED_HEAD
  else
    rc=$?
    rm -f "$snapshot"
    return "$rc"
  fi
  rm -f "$snapshot"
  [ "$exact_head" = "$validated_head" ] || {
    fm_nm_error "approval head $exact_head does not match worktree HEAD $validated_head"
    return 2
  }
  approval=$(fm_nm_approval_path)
  if [ -e "$approval" ] || [ -L "$approval" ]; then
    [ -f "$approval" ] && [ ! -L "$approval" ] || {
      fm_nm_error "approval path is not a regular file at $approval"
      return 2
    }
  fi
  tmp=$(mktemp "$dir/.no-mistakes-readiness-approval.XXXXXX") || return 2
  chmod 600 "$tmp" || { rm -f "$tmp"; return 2; }
  {
    printf 'version=1\n'
    printf 'authority=firstmate\n'
    printf 'task=%s\n' "$id"
    printf 'head=%s\n' "$validated_head"
    printf 'evidence_sha256=%s\n' "$reviewed_evidence_sha256"
  } > "$tmp"
  live_sha256=$(fm_pr_sha256 "$record") || {
    rm -f "$tmp"
    fm_nm_error "cannot re-hash readiness evidence before semantic approval publication"
    return 2
  }
  if [ "$live_sha256" != "$reviewed_evidence_sha256" ]; then
    rm -f "$tmp"
    fm_nm_error "readiness evidence changed after review and before semantic approval publication"
    return 2
  fi
  fm_session_lock_owned_by_self "$STATE" || {
    rm -f "$tmp"
    fm_nm_error "Firstmate session-lock ownership changed before semantic approval publication"
    return 2
  }
  mv "$tmp" "$approval" || { rm -f "$tmp"; return 2; }
  printf 'approved: Firstmate semantic readiness for task %s at %s\n' "$id" "$validated_head"
}

fm_nm_timeout_run() { # <worktree> <no-mistakes args...>
  local worktree=$1 timeout_secs=${FM_NM_STATUS_TIMEOUT:-10}
  shift
  case "$timeout_secs" in ''|*[!0-9]*) timeout_secs=10 ;; esac
  if command -v timeout >/dev/null 2>&1; then
    (cd "$worktree" && timeout "$timeout_secs" no-mistakes "$@") 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    (cd "$worktree" && gtimeout "$timeout_secs" no-mistakes "$@") 2>/dev/null
  elif command -v perl >/dev/null 2>&1; then
    (cd "$worktree" && perl -e '
      my $timeout = shift;
      my $pid = fork;
      die "fork failed" unless defined $pid;
      if (!$pid) { setpgrp(0, 0); exec @ARGV }
      local $SIG{ALRM} = sub {
        kill "TERM", -$pid;
        select undef, undef, undef, 0.2;
        kill "KILL", -$pid;
        exit 124;
      };
      alarm $timeout;
      waitpid $pid, 0;
      exit($? >> 8);
    ' "$timeout_secs" no-mistakes "$@") 2>/dev/null
  else
    return 1
  fi
}

fm_nm_toon_field() { # <TOON> <field>
  printf '%s\n' "$1" | awk -v field="$2" '
    $0 ~ "^[[:space:]]*" field ":[[:space:]]" {
      sub("^[[:space:]]*" field ":[[:space:]]*", "")
      if ($0 ~ /^".*"$/) { sub(/^"/, ""); sub(/"$/, "") }
      print
      exit
    }
  '
}

fm_nm_run_status() { # [<run-id>]
  local run=${1:-}
  if [ -n "$run" ]; then
    fm_nm_timeout_run "$FM_NM_WORKTREE" axi status --run "$run"
  else
    fm_nm_timeout_run "$FM_NM_WORKTREE" axi status
  fi
}

fm_nm_run_matches_task() { # <status-output>
  local output=$1 branch run_head resolved worktree_branch worktree_head
  branch=$(fm_nm_toon_field "$output" branch)
  run_head=$(fm_nm_toon_field "$output" head)
  [ -n "$branch" ] && [ "$branch" = "fm/$FM_NM_ID" ] || return 1
  [ -n "$run_head" ] || return 1
  worktree_branch=$(git -C "$FM_NM_WORKTREE" branch --show-current 2>/dev/null) || return 1
  [ "$worktree_branch" = "fm/$FM_NM_ID" ] || return 1
  worktree_head=$(git -C "$FM_NM_WORKTREE" rev-parse HEAD 2>/dev/null) || return 1
  resolved=$(git -C "$FM_NM_WORKTREE" rev-parse "$run_head^{commit}" 2>/dev/null) || return 1
  [ "$resolved" = "$worktree_head" ] \
    || git -C "$FM_NM_WORKTREE" merge-base --is-ancestor "$worktree_head" "$resolved" 2>/dev/null
}

fm_nm_run_terminal() { # <status-output>
  local output=$1 status outcome
  status=$(fm_nm_toon_field "$output" status)
  outcome=$(fm_nm_toon_field "$output" outcome)
  case "$status" in completed|failed|cancelled) return 0 ;; esac
  case "$outcome" in passed|failed|cancelled) return 0 ;; esac
  return 1
}

fm_nm_monitor_journal_path() {
  printf '%s/%s.no-mistakes-monitor' "$STATE" "$FM_NM_ID"
}

fm_nm_monitor_journal_load() { # <journal>
  local journal=$1 key version line_count expected_label
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  for key in version task run submitted_head session workspace; do
    [ "$(grep -c "^$key=" "$journal" 2>/dev/null || true)" -eq 1 ] || return 1
  done
  version=$(fm_meta_get "$journal" version)
  if [ "$version" = 0 ]; then
    for key in token label; do
      [ "$(grep -c "^$key=" "$journal" 2>/dev/null || true)" -eq 1 ] || return 1
    done
    line_count=$(awk 'END { print NR + 0 }' "$journal")
    [ "$line_count" -eq 8 ] || return 1
    FM_NM_J_VERSION=$version
    FM_NM_J_TASK=$(fm_meta_get "$journal" task)
    FM_NM_J_RUN=$(fm_meta_get "$journal" run)
    FM_NM_J_HEAD=$(fm_meta_get "$journal" submitted_head)
    FM_NM_J_SESSION=$(fm_meta_get "$journal" session)
    FM_NM_J_WORKSPACE=$(fm_meta_get "$journal" workspace)
    FM_NM_J_TOKEN=$(fm_meta_get "$journal" token)
    FM_NM_J_LABEL=$(fm_meta_get "$journal" label)
    [ "$FM_NM_J_TASK" = "$FM_NM_ID" ] && [ "${#FM_NM_J_TOKEN}" -eq 22 ] || return 1
    case "$FM_NM_J_TOKEN" in *[!A-Za-z0-9_-]*) return 1 ;; esac
    expected_label="no-mistakes view ${FM_NM_J_RUN:0:8} $FM_NM_J_TOKEN"
    [ "$FM_NM_J_LABEL" = "$expected_label" ] || return 1
    for key in "$FM_NM_J_RUN" "$FM_NM_J_HEAD" "$FM_NM_J_SESSION" "$FM_NM_J_WORKSPACE"; do
      case "$key" in ''|*[!A-Za-z0-9._@%+-]*) return 1 ;; esac
    done
    return 4
  fi
  [ "$version" = 1 ] || return 1
  for key in tab pane executable; do
    [ "$(grep -c "^$key=" "$journal" 2>/dev/null || true)" -eq 1 ] || return 1
  done
  line_count=$(awk 'END { print NR + 0 }' "$journal")
  [ "$line_count" -eq 9 ] || return 1
  FM_NM_J_VERSION=$version
  FM_NM_J_TASK=$(fm_meta_get "$journal" task)
  FM_NM_J_RUN=$(fm_meta_get "$journal" run)
  FM_NM_J_HEAD=$(fm_meta_get "$journal" submitted_head)
  FM_NM_J_SESSION=$(fm_meta_get "$journal" session)
  FM_NM_J_WORKSPACE=$(fm_meta_get "$journal" workspace)
  FM_NM_J_TAB=$(fm_meta_get "$journal" tab)
  FM_NM_J_PANE=$(fm_meta_get "$journal" pane)
  FM_NM_J_EXECUTABLE=$(fm_meta_get "$journal" executable)
  [ "$FM_NM_J_VERSION" = 1 ] && [ "$FM_NM_J_TASK" = "$FM_NM_ID" ] || return 1
  for key in "$FM_NM_J_RUN" "$FM_NM_J_HEAD" "$FM_NM_J_SESSION" "$FM_NM_J_WORKSPACE" \
    "${FM_NM_J_TAB//:/_}" "${FM_NM_J_PANE//:/_}"; do
    case "$key" in ''|*[!A-Za-z0-9._@%+-]*) return 1 ;; esac
  done
  case "$FM_NM_J_EXECUTABLE" in /*) ;; *) return 1 ;; esac
  case "$FM_NM_J_EXECUTABLE" in *$'\t'*|*$'\n'*) return 1 ;; esac
}

fm_nm_monitor_pane_record() { # <session> <pane>
  local output status pane tab workspace
  if output=$(fm_backend_herdr_cli "$1" pane get "$2" 2>&1); then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    if printf '%s' "$output" | jq -e '.error.code == "pane_not_found"' >/dev/null 2>&1; then
      return 3
    fi
    return 2
  fi
  pane=$(printf '%s' "$output" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  tab=$(printf '%s' "$output" | jq -r '.result.pane.tab_id // empty' 2>/dev/null)
  workspace=$(printf '%s' "$output" | jq -r '.result.pane.workspace_id // empty' 2>/dev/null)
  [ "$pane" = "$2" ] && [ -n "$tab" ] && [ -n "$workspace" ] || return 2
  printf '%s\t%s\t%s' "$pane" "$tab" "$workspace"
}

fm_nm_canonical_executable() { # <path>
  local path=$1 link dir count=0
  case "$path" in /*) ;; *) return 1 ;; esac
  while [ -L "$path" ]; do
    [ "$count" -lt 40 ] || return 1
    link=$(readlink "$path" 2>/dev/null) || return 1
    case "$link" in
      /*) path=$link ;;
      *) path="${path%/*}/$link" ;;
    esac
    count=$((count + 1))
  done
  [ -f "$path" ] && [ -x "$path" ] || return 1
  dir=$(cd "${path%/*}" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s' "$dir" "${path##*/}"
}

fm_nm_monitor_process_matches() { # <session> <pane> <run> <executable>
  local output candidate expected
  output=$(fm_backend_herdr_cli "$1" pane process-info --pane "$2" 2>/dev/null) || return 1
  candidate=$(printf '%s' "$output" | jq -er --arg pane "$2" --arg run "$3" '
    select(.result.process_info.pane_id == $pane)
    | select((.result.process_info.foreground_processes | type) == "array")
    | select((.result.process_info.foreground_processes | length) == 1)
    | .result.process_info.foreground_processes[0].argv
    | select(type == "array" and length == 4)
    | select((.[0] | type) == "string")
    | select(.[1] == "attach" and .[2] == "--run" and .[3] == $run)
    | .[0]
  ' 2>/dev/null) || return 1
  candidate=$(fm_nm_canonical_executable "$candidate") || return 1
  expected=$(fm_nm_canonical_executable "$4") || return 1
  [ "$candidate" = "$expected" ]
}

fm_nm_monitor_process_wait() { # <session> <pane> <run> <executable>
  local session=$1 pane=$2 run=$3 executable=$4 attempt=0 attempts=${FM_NM_MONITOR_PROCESS_ATTEMPTS:-30}
  case "$attempts" in ''|*[!0-9]*) attempts=30 ;; esac
  while [ "$attempt" -lt "$attempts" ]; do
    fm_nm_monitor_process_matches "$session" "$pane" "$run" "$executable" && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

fm_nm_run_matches_journal() { # <status-output>
  local output=$1 branch run_head resolved_run resolved_submitted
  fm_nm_run_matches_task "$output" || return 1
  branch=$(fm_nm_toon_field "$output" branch)
  run_head=$(fm_nm_toon_field "$output" head)
  [ "$branch" = "fm/$FM_NM_ID" ] && [ -n "$run_head" ] || return 1
  resolved_run=$(git -C "$FM_NM_WORKTREE" rev-parse "$run_head^{commit}" 2>/dev/null) || return 1
  resolved_submitted=$(git -C "$FM_NM_WORKTREE" rev-parse "$FM_NM_J_HEAD^{commit}" 2>/dev/null) || return 1
  [ "$resolved_run" = "$resolved_submitted" ] \
    || git -C "$FM_NM_WORKTREE" merge-base --is-ancestor "$resolved_submitted" "$resolved_run" 2>/dev/null
}

fm_nm_monitor_publish() { # <journal> <run> <head> <session> <workspace> <tab> <pane> <executable>
  local journal=$1 run=$2 head=$3 session=$4 workspace=$5 tab=$6 pane=$7 executable=$8 tmp
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$STATE/.${FM_NM_ID}.no-mistakes-monitor.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  {
    printf 'version=1\n'
    printf 'task=%s\n' "$FM_NM_ID"
    printf 'run=%s\n' "$run"
    printf 'submitted_head=%s\n' "$head"
    printf 'session=%s\n' "$session"
    printf 'workspace=%s\n' "$workspace"
    printf 'tab=%s\n' "$tab"
    printf 'pane=%s\n' "$pane"
    printf 'executable=%s\n' "$executable"
  } > "$tmp"
  mv "$tmp" "$journal" || { rm -f "$tmp"; return 1; }
}

fm_nm_monitor_publish_attempt() { # <journal> <run> <head> <session> <workspace> <token> <label>
  local journal=$1 run=$2 head=$3 session=$4 workspace=$5 token=$6 label=$7 tmp
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$STATE/.${FM_NM_ID}.no-mistakes-monitor-attempt.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  {
    printf 'version=0\n'
    printf 'task=%s\n' "$FM_NM_ID"
    printf 'run=%s\n' "$run"
    printf 'submitted_head=%s\n' "$head"
    printf 'session=%s\n' "$session"
    printf 'workspace=%s\n' "$workspace"
    printf 'token=%s\n' "$token"
    printf 'label=%s\n' "$label"
  } > "$tmp"
  mv "$tmp" "$journal" || { rm -f "$tmp"; return 1; }
}

fm_nm_monitor_cleanup_created() { # <journal> <session> <pane>
  local journal=$1 session=$2 pane=$3 status
  [ -n "$pane" ] || return 1
  fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$pane" || true
  fm_nm_monitor_pane_record "$session" "$pane" >/dev/null 2>&1 && status=0 || status=$?
  [ "$status" -eq 3 ] || return 1
  rm -f "$journal"
}

fm_nm_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_nm_monitor_create_under_lock() { # <journal> <run> <submitted-head>
  local journal=$1 run=$2 submitted_head=$3 session workspace task_pane focus_before output
  local status tab pane record nm_bin command short_run token label
  session=$(fm_meta_get "$FM_NM_META" herdr_session)
  workspace=$(fm_meta_get "$FM_NM_META" herdr_workspace_id)
  task_pane=$(fm_meta_get "$FM_NM_META" herdr_pane_id)
  record=$(fm_nm_monitor_pane_record "$session" "$task_pane") || {
    fm_nm_error "cannot verify task $FM_NM_ID exact Herdr pane before monitor creation"
    return 2
  }
  [ "${record#*$'\t'}" = "$(fm_meta_get "$FM_NM_META" herdr_tab_id)"$'\t'"$workspace" ] || {
    fm_nm_error "task $FM_NM_ID Herdr pane no longer matches its recorded tab and workspace"
    return 2
  }
  nm_bin=$(command -v no-mistakes 2>/dev/null) || nm_bin=
  nm_bin=$(fm_nm_canonical_executable "$nm_bin") || nm_bin=
  if [ -z "$nm_bin" ]; then
    fm_nm_error "no-mistakes command is unavailable for the attach pane"
    return 2
  fi
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    fm_nm_error "cannot capture exact Herdr focus before monitor creation"
    return 2
  }
  token=$(fm_backend_herdr_projection_id) || {
    fm_nm_error "cannot generate Herdr monitor attempt token"
    return 2
  }
  short_run=${run:0:8}
  label="no-mistakes view $short_run $token"
  fm_nm_monitor_publish_attempt "$journal" "$run" "$submitted_head" "$session" "$workspace" "$token" "$label" || {
    fm_nm_error "cannot publish Herdr monitor attempt journal"
    return 2
  }
  if output=$(fm_backend_herdr_cli "$session" tab create --workspace "$workspace" \
    --cwd "$FM_NM_WORKTREE" --label "$label" --no-focus 2>/dev/null); then
    status=0
  else
    status=$?
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "no-mistakes monitor create" || return 2
  [ "$status" -eq 0 ] || {
    fm_nm_error "Herdr monitor tab creation failed ambiguously; preserving its attempt journal"
    return 2
  }
  tab=$(printf '%s' "$output" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$output" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  [ -n "$tab" ] && [ -n "$pane" ] || {
    fm_nm_error "Herdr monitor tab creation returned incomplete exact IDs; preserving its attempt journal"
    return 2
  }
  record=$(fm_nm_monitor_pane_record "$session" "$pane") || record=
  if [ "$record" != "$pane"$'\t'"$tab"$'\t'"$workspace" ]; then
    fm_nm_monitor_cleanup_created "$journal" "$session" "$pane" || true
    fm_nm_error "Herdr monitor tab did not converge to its exact workspace binding; preserving any unconfirmed attempt"
    return 2
  fi
  if ! fm_nm_monitor_publish "$journal" "$run" "$submitted_head" "$session" "$workspace" "$tab" "$pane" "$nm_bin"; then
    fm_nm_monitor_cleanup_created "$journal" "$session" "$pane" || true
    fm_nm_error "cannot publish exact Herdr monitor journal; preserving any unconfirmed attempt"
    return 2
  fi
  command="exec $(fm_nm_shell_quote "$nm_bin") attach --run $(fm_nm_shell_quote "$run")"
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$command" >/dev/null 2>&1; then
    fm_nm_monitor_cleanup_created "$journal" "$session" "$pane" || true
    fm_nm_error "could not start no-mistakes attach in exact Herdr monitor pane; preserving any unconfirmed monitor"
    return 2
  fi
  if ! fm_nm_monitor_process_wait "$session" "$pane" "$run" "$nm_bin"; then
    fm_nm_monitor_cleanup_created "$journal" "$session" "$pane" || true
    fm_nm_error "no-mistakes attach did not become the exact foreground process; preserving any unconfirmed monitor"
    return 2
  fi
  printf 'visible: no-mistakes run %s attached in Herdr pane %s without focus change\n' "$run" "$pane"
}

fm_nm_with_presentation_lock() { # <session> <function> [args...]
  local session=$1 operation=$2 lock attempt=0 attempts=${FM_NM_PRESENTATION_LOCK_ATTEMPTS:-50} rc
  shift 2
  case "$attempts" in ''|*[!0-9]*) attempts=50 ;; esac
  lock=$(fm_backend_herdr_presentation_session_lock_path "$session" 2>/dev/null) || {
    fm_nm_error "cannot resolve the shared Herdr presentation lock for session $session"
    return 2
  }
  while ! fm_lock_try_acquire "$lock"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$attempts" ] || {
      fm_nm_error "shared Herdr presentation lock is busy for session $session"
      return 2
    }
    sleep 0.1
  done
  "$operation" "$@" && rc=0 || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

fm_nm_monitor_create() { # <journal> <run> <submitted-head>
  local session
  session=$(fm_meta_get "$FM_NM_META" herdr_session)
  fm_nm_with_presentation_lock "$session" fm_nm_monitor_create_under_lock "$@"
}

fm_nm_monitor_clear_attempt_locked() { # <task-id> <attempt-token>
  local id=$1 supplied_token=$2 journal status
  fm_nm_task_load "$id" || return $?
  [ "$FM_NM_BACKEND" = herdr ] || {
    fm_nm_error "task $id is backend=$FM_NM_BACKEND, not Herdr"
    return 2
  }
  journal=$(fm_nm_monitor_journal_path)
  fm_nm_monitor_journal_load "$journal" && status=0 || status=$?
  [ "$status" -eq 4 ] || {
    fm_nm_error "task $id has no valid incomplete Herdr monitor attempt to clear"
    return 2
  }
  [ "$supplied_token" = "$FM_NM_J_TOKEN" ] || {
    fm_nm_error "attempt token does not match the exact journal"
    return 2
  }
  rm -f "$journal" || return 2
  printf 'cleared: inspected Herdr monitor attempt %s; no pane was discovered or mutated\n' "$supplied_token"
}

fm_nm_with_monitor_task_lock() { # <task-id> <function> [args...]
  local id=$1 operation=$2 lock rc
  shift 2
  fm_task_id_creation_valid "$id" || {
    fm_nm_error "invalid task id '$id'"
    return 2
  }
  fm_session_lock_owned_by_self "$STATE" || {
    fm_nm_error "monitor lifecycle can be changed only by the lock-owning Firstmate session"
    return 2
  }
  mkdir -p "$STATE" || return 2
  lock="$STATE/.${id}.no-mistakes-monitor.lock"
  if ! fm_lock_try_acquire "$lock"; then
    fm_nm_error "monitor reconciliation is already active for task $id"
    return 2
  fi
  fm_session_lock_owned_by_self "$STATE" || {
    fm_lock_release "$lock"
    fm_nm_error "Firstmate session-lock ownership changed before monitor lifecycle mutation"
    return 2
  }
  "$operation" "$@" && rc=0 || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

fm_nm_monitor_clear_attempt() { # <task-id> <attempt-token>
  fm_nm_with_monitor_task_lock "$1" fm_nm_monitor_clear_attempt_locked "$@"
}

fm_nm_monitor_retire_under_lock() { # <journal> <status-output>
  local journal=$1 status_output=$2 record status
  fm_nm_run_terminal "$status_output" || return 1
  record=$(fm_nm_monitor_pane_record "$FM_NM_J_SESSION" "$FM_NM_J_PANE") && status=0 || status=$?
  if [ "$status" -eq 3 ]; then
    rm -f "$journal"
    printf 'retired: terminal no-mistakes run %s monitor was already absent\n' "$FM_NM_J_RUN"
    return 0
  fi
  [ "$status" -eq 0 ] \
    && [ "$record" = "$FM_NM_J_PANE"$'\t'"$FM_NM_J_TAB"$'\t'"$FM_NM_J_WORKSPACE" ] || {
      fm_nm_error "terminal run $FM_NM_J_RUN monitor pane is ambiguous; preserving it and its journal"
      return 2
    }
  fm_nm_monitor_process_matches "$FM_NM_J_SESSION" "$FM_NM_J_PANE" "$FM_NM_J_RUN" "$FM_NM_J_EXECUTABLE" || {
    fm_nm_error "terminal run $FM_NM_J_RUN monitor pane no longer proves the exact attach process; preserving it"
    return 2
  }
  fm_backend_herdr_projection_close_pane_focus_preserving "$FM_NM_J_SESSION" "$FM_NM_J_PANE" || true
  fm_nm_monitor_pane_record "$FM_NM_J_SESSION" "$FM_NM_J_PANE" >/dev/null 2>&1 && status=0 || status=$?
  [ "$status" -eq 3 ] || {
    fm_nm_error "terminal run $FM_NM_J_RUN monitor close was not positively confirmed; preserving its journal"
    return 2
  }
  rm -f "$journal"
  printf 'retired: terminal no-mistakes run %s Herdr presentation pane %s\n' "$FM_NM_J_RUN" "$FM_NM_J_PANE"
}

fm_nm_monitor_retire() { # <journal> <status-output>
  fm_nm_with_presentation_lock "$FM_NM_J_SESSION" fm_nm_monitor_retire_under_lock "$@"
}

fm_nm_monitor_reconcile_locked() { # <task-id>
  local id=$1 journal output run submitted_head record status
  fm_nm_task_load "$id" || return $?
  journal=$(fm_nm_monitor_journal_path)
  if [ "$FM_NM_BACKEND" != herdr ]; then
    [ ! -e "$journal" ] || {
      fm_nm_error "non-Herdr task $id has a monitor journal; preserving it for inspection"
      return 2
    }
    printf 'not-applicable: backend=%s keeps existing supervision and gets no attach pane\n' "$FM_NM_BACKEND"
    return 0
  fi
  fm_backend_source herdr
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    fm_nm_monitor_journal_load "$journal" && status=0 || status=$?
    if [ "$status" -eq 4 ]; then
      fm_nm_error "incomplete Herdr monitor creation attempt at $journal; inspect session=$FM_NM_J_SESSION workspace=$FM_NM_J_WORKSPACE label='$FM_NM_J_LABEL', preserve or retire any exact presentation pane in Herdr, then run '$0 monitor-clear-attempt $id $FM_NM_J_TOKEN'"
      return 2
    fi
    if [ "$status" -ne 0 ]; then
      fm_nm_error "malformed monitor journal at $journal; preserving it"
      return 2
    fi
    output=$(fm_nm_run_status "$FM_NM_J_RUN") || output=
    [ -n "$output" ] && [ "$(fm_nm_toon_field "$output" id)" = "$FM_NM_J_RUN" ] || {
      fm_nm_error "cannot verify exact no-mistakes run $FM_NM_J_RUN; preserving its monitor"
      return 2
    }
    fm_nm_run_matches_journal "$output" || {
      fm_nm_error "no-mistakes run $FM_NM_J_RUN no longer matches its journaled branch and submitted head; preserving its monitor"
      return 2
    }
    if fm_nm_run_terminal "$output"; then
      fm_nm_monitor_retire "$journal" "$output"
      return $?
    fi
    record=$(fm_nm_monitor_pane_record "$FM_NM_J_SESSION" "$FM_NM_J_PANE") && status=0 || status=$?
    if [ "$status" -eq 3 ]; then
      rm -f "$journal"
      fm_nm_monitor_create "$journal" "$FM_NM_J_RUN" "$FM_NM_J_HEAD"
      return $?
    fi
    if [ "$status" -ne 0 ] \
      || [ "$record" != "$FM_NM_J_PANE"$'\t'"$FM_NM_J_TAB"$'\t'"$FM_NM_J_WORKSPACE" ] \
      || ! fm_nm_monitor_process_matches "$FM_NM_J_SESSION" "$FM_NM_J_PANE" "$FM_NM_J_RUN" "$FM_NM_J_EXECUTABLE"; then
        fm_nm_error "active run $FM_NM_J_RUN has an ambiguous or repurposed monitor pane; refusing a duplicate"
        return 2
    fi
    printf 'visible: no-mistakes run %s remains attached in exact Herdr pane %s\n' "$FM_NM_J_RUN" "$FM_NM_J_PANE"
    return 0
  fi
  output=$(fm_nm_run_status) || output=
  [ -n "$output" ] || {
    printf 'pending: no no-mistakes run is visible for task %s yet\n' "$id"
    return 0
  }
  fm_nm_run_matches_task "$output" || {
    printf 'pending: no exact branch-and-head-matched no-mistakes run is visible for task %s\n' "$id"
    return 0
  }
  run=$(fm_nm_toon_field "$output" id)
  case "$run" in ''|*[!A-Za-z0-9._-]*)
    fm_nm_error "AXI status returned an invalid run id"
    return 2
  esac
  if fm_nm_run_terminal "$output"; then
    printf 'retired: exact no-mistakes run %s is already terminal; no monitor created\n' "$run"
    return 0
  fi
  submitted_head=$(git -C "$FM_NM_WORKTREE" rev-parse HEAD 2>/dev/null) || return 2
  fm_nm_monitor_create "$journal" "$run" "$submitted_head"
}

fm_nm_monitor_reconcile() { # <task-id>
  fm_nm_with_monitor_task_lock "$1" fm_nm_monitor_reconcile_locked "$@"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  init|check|monitor-reconcile)
    command=$1
    id=${2:-}
    [ -n "$id" ] && [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    case "$command" in
      init) fm_nm_init "$id" ;;
      check) fm_nm_check "$id" ;;
      monitor-reconcile) fm_nm_monitor_reconcile "$id" ;;
    esac
    ;;
  approve)
    id=${2:-}
    head=${3:-}
    evidence_sha256=${4:-}
    [ -n "$id" ] && [ -n "$head" ] && [ -n "$evidence_sha256" ] && [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    fm_nm_approve "$id" "$head" "$evidence_sha256"
    ;;
  monitor-clear-attempt)
    id=${2:-}
    token=${3:-}
    [ -n "$id" ] && [ -n "$token" ] && [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    fm_nm_monitor_clear_attempt "$id" "$token"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
