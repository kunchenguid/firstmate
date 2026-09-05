#!/usr/bin/env bash
# Shared live-remote proof for safety decisions that would otherwise trust stale
# refs/remotes/* state. Every positive verdict begins with git ls-remote against
# a configured push destination. Local transports count only when their Git
# common directory differs from this repository. Other transports prove only
# that a remote Git process advertised the branch, not that it reads a repository
# independent of this working copy.
# Advertised branch refs whose tip objects are absent locally are fetched together
# before checking ancestry.
#
# Public functions:
#   fm_git_live_remote_deadline
#     Print one absolute deadline from the configured overall probe budget.
#   fm_git_live_remote_heads <repo> [deadline]
#     Print the commit IDs advertised by every configured push destination after
#     fetching any advertised tip object that is not present locally.
#   fm_git_commit_is_in_live_remote_heads <repo> <commit> <heads> [deadline]
#     True when commit is contained by a captured live-remote head set.
#   fm_git_commit_is_on_live_remote <repo> <commit> [deadline]
#     True when the commit is contained by any branch currently advertised by
#     any configured push destination.

if ! command -v fm_run_timed >/dev/null 2>&1; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
fi

FM_GIT_LIVE_REMOTE_NOT_FOUND=1
FM_GIT_LIVE_REMOTE_TIMEOUT=2
FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED=3
FM_GIT_LIVE_REMOTE_PROBE_FAILED=4
FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED=125
FM_GIT_LIVE_REMOTE_NON_LOCAL=126

fm_git_live_remote_deadline() {
  local budget=${FM_GIT_LIVE_REMOTE_BUDGET_SECS:-45}
  case "$budget" in
    ''|*[!0-9]*|0) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  printf '%s\n' "$((SECONDS + budget))"
}

fm_git_live_remote_operation_timeout() {
  local operation_timeout=${FM_GIT_LIVE_REMOTE_OPERATION_TIMEOUT_SECS:-15}
  case "$operation_timeout" in
    ''|*[!0-9]*|0) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  printf '%s\n' "$operation_timeout"
}

fm_git_live_remote_run_raw() {  # <deadline> <operation-timeout> <git-args...>
  local deadline=$1 operation_timeout=$2 remaining bound budget_limited=0 rc=0
  shift 2
  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || return "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED"
  bound=$operation_timeout
  if [ "$remaining" -lt "$bound" ]; then
    bound=$remaining
    budget_limited=1
  fi
  fm_run_timed "$bound" env \
    GIT_TERMINAL_PROMPT=0 \
    GCM_INTERACTIVE=Never \
    GIT_ASKPASS=false \
    SSH_ASKPASS=false \
    SSH_ASKPASS_REQUIRE=never \
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" \
    git "$@" </dev/null || rc=$?
  if [ "$rc" -eq 124 ]; then
    [ "$budget_limited" -eq 0 ] || return "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED"
  fi
  return "$rc"
}

fm_git_live_remote_run() {  # <deadline> <operation-timeout> <git-args...>
  local rc=0
  fm_git_live_remote_run_raw "$@" || rc=$?
  case "$rc" in
    0) return 0 ;;
    124) return "$FM_GIT_LIVE_REMOTE_TIMEOUT" ;;
    "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ;;
    *) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
}

fm_git_live_remote_note_status() {  # <current> <new>
  local current=$1 new=$2
  case "$new:$current" in
    "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED":*) printf '%s\n' "$new" ;;
    "$FM_GIT_LIVE_REMOTE_TIMEOUT":"$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED") printf '%s\n' "$current" ;;
    "$FM_GIT_LIVE_REMOTE_TIMEOUT":*) printf '%s\n' "$new" ;;
    "$FM_GIT_LIVE_REMOTE_PROBE_FAILED":0) printf '%s\n' "$new" ;;
    *) printf '%s\n' "$current" ;;
  esac
}

fm_git_live_remote_common_dir() {  # <repo> <deadline> <operation-timeout>
  local repo=$1 deadline=$2 operation_timeout=$3 common_dir rc=0
  common_dir=$(fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
    -C "$repo" rev-parse --git-common-dir 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    124) return "$FM_GIT_LIVE_REMOTE_TIMEOUT" ;;
    "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ;;
    *) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  case "$common_dir" in /*) ;; *) common_dir="$repo/$common_dir" ;; esac
  common_dir=$(CDPATH='' cd -- "$common_dir" 2>/dev/null && pwd -P) \
    || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  printf '%s\n' "$common_dir"
}

fm_git_live_remote_local_common_dir() {  # <repo-real> <url> <deadline> <operation-timeout>
  local repo_real=$1 url=$2 deadline=$3 operation_timeout=$4 path
  case "$url" in
    file://*/*)
      path=${url#file://}
      path=/${path#*/}
      ;;
    file://*) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
    *://*|*:*|'') return "$FM_GIT_LIVE_REMOTE_NON_LOCAL" ;;
    /*) path=$url ;;
    *) path="$repo_real/$url" ;;
  esac
  fm_git_live_remote_common_dir "$path" "$deadline" "$operation_timeout"
}

fm_git_live_remote_heads_for_url() {  # <repo> <repo-real> <common-dir> <url> <deadline> <operation-timeout>
  local repo=$1 repo_real=$2 common_dir=$3 remote_url=$4 deadline=$5 operation_timeout=$6
  local remote_common_dir heads line remote_head remote_ref rc=0 status=0 scan_exhausted=0
  local -a missing_refs
  remote_common_dir=$(fm_git_live_remote_local_common_dir \
    "$repo_real" "$remote_url" "$deadline" "$operation_timeout") || rc=$?
  case "$rc" in
    0) [ "$remote_common_dir" != "$common_dir" ] || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
    "$FM_GIT_LIVE_REMOTE_NON_LOCAL") ;;
    "$FM_GIT_LIVE_REMOTE_TIMEOUT"|"$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED"|"$FM_GIT_LIVE_REMOTE_PROBE_FAILED") return "$rc" ;;
    *) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  if heads=$(fm_git_live_remote_run "$deadline" "$operation_timeout" \
    -C "$repo" ls-remote --heads "$remote_url" 2>/dev/null); then
    :
  else
    rc=$?
    return "$rc"
  fi
  missing_refs=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    remote_head=${line%%$'\t'*}
    remote_ref=${line#*$'\t'}
    [ -n "$remote_head" ] && [ "$remote_ref" != "$line" ] || continue
    rc=0
    fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
      -C "$repo" cat-file -e "$remote_head^{commit}" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) ;;
      124)
        status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_TIMEOUT")
        missing_refs+=("$remote_ref")
        ;;
      "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED")
        status=$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED
        scan_exhausted=1
        break
        ;;
      *) missing_refs+=("$remote_ref") ;;
    esac
  done <<EOF
$heads
EOF
  if [ "$scan_exhausted" -eq 0 ] && [ "${#missing_refs[@]}" -gt 0 ]; then
    if fm_git_live_remote_run "$deadline" "$operation_timeout" \
      -C "$repo" fetch --quiet --no-tags "$remote_url" "${missing_refs[@]}" >/dev/null 2>&1; then
      :
    else
      rc=$?
      status=$(fm_git_live_remote_note_status "$status" "$rc")
    fi
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$SECONDS" -ge "$deadline" ]; then
      status=$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED
      break
    fi
    remote_head=${line%%$'\t'*}
    remote_ref=${line#*$'\t'}
    [ -n "$remote_head" ] && [ "$remote_ref" != "$line" ] || continue
    printf '%s\n' "$remote_head"
  done <<EOF
$heads
EOF
  return "$status"
}

fm_git_live_remote_heads() {  # <repo> [deadline]
  local repo=$1 deadline=${2:-} operation_timeout remotes remote remote_urls remote_url url_heads
  local rc status=0 repo_real common_dir
  operation_timeout=$(fm_git_live_remote_operation_timeout) || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  [ -n "$deadline" ] || deadline=$(fm_git_live_remote_deadline) \
    || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  case "$deadline" in ''|*[!0-9]*) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;; esac
  [ "$SECONDS" -lt "$deadline" ] || return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED"
  repo_real=$(CDPATH='' cd -- "$repo" 2>/dev/null && pwd -P) \
    || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  rc=0
  common_dir=$(fm_git_live_remote_common_dir "$repo_real" "$deadline" "$operation_timeout") || rc=$?
  case "$rc" in
    0) ;;
    "$FM_GIT_LIVE_REMOTE_TIMEOUT"|"$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED"|"$FM_GIT_LIVE_REMOTE_PROBE_FAILED") return "$rc" ;;
    *) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  rc=0
  remotes=$(fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
    -C "$repo" remote 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    124) return "$FM_GIT_LIVE_REMOTE_TIMEOUT" ;;
    "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ;;
    *) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;;
  esac
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    rc=0
    remote_urls=$(fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
      -C "$repo" remote get-url --push --all "$remote" 2>/dev/null) || rc=$?
    case "$rc" in
      0) ;;
      124) status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_TIMEOUT"); continue ;;
      "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") status=$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED; break ;;
      *) status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"); continue ;;
    esac
    while IFS= read -r remote_url; do
      [ -n "$remote_url" ] || continue
      rc=0
      if url_heads=$(fm_git_live_remote_heads_for_url \
        "$repo" "$repo_real" "$common_dir" "$remote_url" "$deadline" "$operation_timeout"); then
        :
      else
        rc=$?
      fi
      [ -z "$url_heads" ] || printf '%s\n' "$url_heads"
      status=$(fm_git_live_remote_note_status "$status" "$rc")
      [ "$status" -ne "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ] || break
    done <<EOF
$remote_urls
EOF
    [ "$status" -ne "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ] || break
  done <<EOF
$remotes
EOF
  return "$status"
}

fm_git_commit_is_in_live_remote_heads() {  # <repo> <commit> <heads> [deadline]
  local repo=$1 commit=$2 heads=$3 deadline=${4:-} operation_timeout remote_head rc status=0
  operation_timeout=$(fm_git_live_remote_operation_timeout) || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  [ -n "$deadline" ] || deadline=$(fm_git_live_remote_deadline) \
    || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  case "$deadline" in ''|*[!0-9]*) return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED" ;; esac
  while IFS= read -r remote_head; do
    [ -n "$remote_head" ] || continue
    [ "$SECONDS" -lt "$deadline" ] || return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED"
    [ "$commit" != "$remote_head" ] || return 0
    rc=0
    fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
      -C "$repo" cat-file -e "$remote_head^{commit}" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0)
        rc=0
        fm_git_live_remote_run_raw "$deadline" "$operation_timeout" \
          -C "$repo" merge-base --is-ancestor "$commit" "$remote_head" >/dev/null 2>&1 || rc=$?
        case "$rc" in
          0) return 0 ;;
          1) ;;
          124) status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_TIMEOUT") ;;
          "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ;;
          *) status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_PROBE_FAILED") ;;
        esac
        ;;
      124) status=$(fm_git_live_remote_note_status "$status" "$FM_GIT_LIVE_REMOTE_TIMEOUT") ;;
      "$FM_GIT_LIVE_REMOTE_RAW_BUDGET_EXHAUSTED") return "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED" ;;
      *) ;;
    esac
  done <<EOF
$heads
EOF
  [ "$status" -eq 0 ] || return "$status"
  return "$FM_GIT_LIVE_REMOTE_NOT_FOUND"
}

fm_git_commit_is_on_live_remote() {  # <repo> <commit> [deadline]
  local repo=$1 commit=$2 deadline=${3:-} heads snapshot_rc=0 contain_rc=0 status
  [ -n "$deadline" ] || deadline=$(fm_git_live_remote_deadline) \
    || return "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
  if heads=$(fm_git_live_remote_heads "$repo" "$deadline"); then
    :
  else
    snapshot_rc=$?
  fi
  fm_git_commit_is_in_live_remote_heads "$repo" "$commit" "$heads" "$deadline" || contain_rc=$?
  [ "$contain_rc" -ne 0 ] || return 0
  status=$(fm_git_live_remote_note_status "$snapshot_rc" "$contain_rc")
  [ "$status" -ne 0 ] || status=$FM_GIT_LIVE_REMOTE_NOT_FOUND
  return "$status"
}
