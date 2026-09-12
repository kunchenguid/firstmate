#!/usr/bin/env bash
# Shared exact-PID process-tree enumeration for teardown and future resource guards.
#
# This library is sourced, never executed. fm_process_pids_under_roots returns a
# stable snapshot of the current user's processes whose cwd is under one of the
# supplied roots, plus every current-user descendant of those processes.
#
# /proc is the sole cwd coverage authority. There is no lsof (or other) fast
# path: an enumerator that cannot prove coverage is the silent-degradation bug
# in another costume. If /proc cannot establish the snapshot, the caller must
# refuse destructive work rather than report success. A guard that silently
# no-ops is worse than no guard because it is trusted.
# FM_PROCESS_RECORDS binds each exact PID to its birth identity at the decision
# snapshot. Unresolved identity-bound candidates are retained across rescans
# until gone, replaced, or non-live. An attempt aborted by a mid-scan exit or
# replacement does not throw away what it already bound: every cwd root
# discovered for every root scanned, every queued walk node, and the snapshot
# subtree below each of them are carried into the retry, where every carried
# record is re-verified by the same rules before it can be collected. A retry
# that silently narrowed the candidate set would be the same false-success
# shape this library exists to eliminate.
# Descendant walks carry pid+identity together and include or queue a walk PID
# only when its live identity still matches that bound birth identity. A
# recycled PID is never adopted as lineage; a replacement may be signaled only
# if cwd-root discovery independently finds it under a task root. Callers may
# signal only those records after rechecking identity.
#
# Ownership and coverage are separate questions, and conflating them is how a
# guard becomes useless in either direction:
#   - CANNOT BIND a live current-user process's birth identity is uncovered
#     ground: refuse and name that pid, and never let other inspected rows
#     launder partial coverage into a clean result.
#   - CANNOT READ a live current-user process's cwd is weaker evidence, and is
#     handled by where the process sits rather than by refusing outright. If the
#     ancestry walk reached it, it is covered - ancestry never needed its cwd,
#     its identity is bound, and it is signaled like any other record. If it is
#     still outside the owned tree, there is no evidence it belongs to this task,
#     so its pid is DISCLOSED to the operator and teardown proceeds.
#     Refusing on every unreadable cwd would refuse on every ordinary Linux host
#     forever: the user session manager, its pam helper, and the ssh session
#     processes all hide their cwd, so a literal rule yields a teardown that
#     never cleans anything - strictly worse than the bug it guards against.
#     KNOWN LIMITATION, stated rather than hidden: a leaked task process that
#     BOTH hides its cwd AND has detached from this task's tree is not found.
#     That takes a deliberately nondumpable process; the leak class this exists
#     for - headless browser trees and dev servers - are ordinary readable
#     processes. The durable fix is a cgroup or session ownership boundary,
#     which belongs to the resource guard rather than here.
#   - DETERMINED NOT ours (a different-uid process) is simply not our business.
#     Skip it. Foreign processes are filtered before cwd-root collection so one
#     sitting under a task root can never cause a false refusal. They are still
#     traversed as intermediaries so our own descendants below them are found,
#     but they are never included and never signaled.
#     KNOWN LIMITATION, stated rather than hidden: on a hidepid=1 /proc mount a
#     live foreign-uid process's stat read fails and kill -0 reports EPERM, so
#     it is dropped from the snapshot as gone; on hidepid=2 (the logind default
#     on some distributions) foreign /proc entries are invisible to the glob
#     entirely. Either way a foreign-uid intermediary cannot be traversed, so
#     our own descendants sitting below it are undercounted while the reap
#     still reports a clean result. Userspace cannot detect that invisibility -
#     /proc is the sole coverage authority by design, and there is no second
#     source to notice the gap. The durable fix is a cgroup or session
#     ownership boundary, which belongs to the resource guard rather than here.
# The rule underneath: claim what you can observe, disclose what you cannot, and
# refuse only on evidence. Refusing on theory is as useless as passing on faith.
# shellcheck disable=SC2034
set -u

FM_PROCESS_PIDS=
FM_PROCESS_FAILED_DIR=
FM_PROCESS_ENUMERATOR=
FM_PROCESS_ENUMERATION_ERROR=
FM_PROCESS_ROOT_PIDS=
FM_PROCESS_ROOT_RECORDS=
FM_PROCESS_SNAPSHOT=
FM_PROCESS_CURRENT_UID=
FM_PROCESS_RECORDS=
FM_PROCESS_CANDIDATE_PIDS=
FM_PROCESS_CANDIDATE_RECORDS=
FM_PROCESS_MATCH_UID=
FM_PROCESS_MATCH_IDENTITY=
FM_PROCESS_RECORD_STATUS=
FM_PROCESS_MERGED_RECORDS=
FM_PROCESS_RECORD_ERROR_PID=
FM_PROCESS_FOUND_IDENTITY=
FM_PROCESS_RECORD_PIDS=
FM_PROCESS_WALK_RECORDS=
FM_PROCESS_UNSTABLE_RECHECK_PID=
FM_PROCESS_STAT_PPID=
FM_PROCESS_STAT_STATE=
FM_PROCESS_STAT_STARTTIME=
FM_PROCESS_PROC_UID=
FM_PROCESS_UNCOVERED_PIDS=

fm_process_error() {  # <message>
  FM_PROCESS_ENUMERATION_ERROR=$1
  return 1
}

fm_process_snapshot() {
  local proc_root proc_dir line pid ppid uid state starttime identity
  FM_PROCESS_SNAPSHOT=
  FM_PROCESS_CURRENT_UID=$(id -u 2>/dev/null) || {
    fm_process_error "cannot determine the current user's uid"
    return 1
  }
  case "$FM_PROCESS_CURRENT_UID" in
    ''|*[!0-9]*)
      fm_process_error "current user's uid is invalid"
      return 1
      ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  [ -d "$proc_root" ] && [ -r "$proc_root" ] && [ -x "$proc_root" ] || {
    fm_process_error "/proc process-cwd enumeration is unavailable"
    return 1
  }
  for proc_dir in "$proc_root"/[0-9]*; do
    [ -d "$proc_dir" ] || continue
    pid=${proc_dir##*/}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if ! fm_process_stat_record "$pid"; then
      if kill -0 "$pid" 2>/dev/null; then
        fm_process_error "cannot bind process identity for live snapshot pid $pid"
        return 1
      fi
      continue
    fi
    ppid=$FM_PROCESS_STAT_PPID
    state=$FM_PROCESS_STAT_STATE
    starttime=$FM_PROCESS_STAT_STARTTIME
    if ! fm_process_proc_uid "$pid"; then
      [ -d "$proc_dir" ] || continue
      fm_process_error "cannot determine /proc ownership for live snapshot pid $pid"
      return 1
    fi
    uid=$FM_PROCESS_PROC_UID
    if fm_process_record_status "$pid" "starttime=$starttime"; then
      case "$FM_PROCESS_RECORD_STATUS" in
        matching) ;;
        *) continue ;;
      esac
    else
      fm_process_error "cannot bind process identity for live snapshot pid $pid"
      return 1
    fi
    identity="starttime=$starttime"
    printf -v line '%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$uid" "$state" "$identity"
    FM_PROCESS_SNAPSHOT=${FM_PROCESS_SNAPSHOT}${line}
  done
  if [ -z "$FM_PROCESS_SNAPSHOT" ]; then
    fm_process_error "/proc process enumeration found no processes"
    return 1
  fi
}

fm_process_cwd_pids_proc() {  # <canonical-root>
  local dir=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  local line pid ppid uid state identity cwd rc considered=0 inspected=0
  FM_PROCESS_ROOT_PIDS=
  FM_PROCESS_ROOT_RECORDS=
  [ -d "$proc_root" ] && [ -r "$proc_root" ] && [ -x "$proc_root" ] || {
    fm_process_error "/proc process-cwd enumeration is unavailable"
    return 1
  }
  while IFS=$'\t' read -r pid ppid uid state identity; do
    [ -n "$pid" ] || continue
    case "$state" in
      Z*) continue ;;
    esac
    [ "$uid" = "$FM_PROCESS_CURRENT_UID" ] || continue
    considered=$((considered + 1))
    [ -n "$identity" ] || {
      fm_process_error "the /proc process-cwd scan has no birth identity for pid $pid"
      return 1
    }
    if cwd=$(readlink "$proc_root/$pid/cwd" 2>/dev/null); then
      inspected=$((inspected + 1))
      case "$cwd" in
        "$dir"|"$dir"/*)
          if fm_process_require_matching_record "$pid" "$identity" "cwd root"; then
            :
          else
            rc=$?
            [ "$rc" -eq 2 ] && FM_PROCESS_UNSTABLE_RECHECK_PID=$pid
            return "$rc"
          fi
          FM_PROCESS_ROOT_PIDS=${FM_PROCESS_ROOT_PIDS}${pid}$'\n'
          FM_PROCESS_ROOT_RECORDS=${FM_PROCESS_ROOT_RECORDS}${pid}$'\t'${identity}$'\n'
          ;;
      esac
    else
      if fm_process_record_status "$pid" "$identity"; then
        case "$FM_PROCESS_RECORD_STATUS" in
          matching) ;;
          gone|replaced|non-live) continue ;;
        esac
      else
        fm_process_error "cannot bind process identity for live cwd-inspection pid $pid"
        return 1
      fi
      # Live, ours, and its cwd cannot be read (a nondumpable process: the user
      # session manager, its pam helper, and the ssh session processes are all
      # like this on an ordinary Linux login). It cannot serve as a cwd ROOT,
      # but that is not by itself evidence of a leak. Record it and decide once
      # the owned tree is known: still outside the tree means no evidence it is
      # ours, so it is disclosed and teardown proceeds. Refusing here instead
      # would refuse on every ordinary host forever, which is a guard that never
      # cleans anything - as useless as one that always passes. A pid that is
      # already gone here is ordinary churn, not a leak and not a refusal: it is
      # skipped, exactly like a pid that disappears during the snapshot.
      FM_PROCESS_UNCOVERED_PIDS=${FM_PROCESS_UNCOVERED_PIDS}${pid}$'\n'
      continue
    fi
  done <<< "$FM_PROCESS_SNAPSHOT"
  if [ "$considered" -gt 0 ] && [ "$inspected" -eq 0 ]; then
    fm_process_error "/proc process-cwd enumeration could not inspect any process"
    return 1
  fi
}

fm_process_cwd_pids() {  # <canonical-root>
  local dir=$1
  FM_PROCESS_ENUMERATOR=proc
  fm_process_cwd_pids_proc "$dir"
}

fm_process_pid_list_contains() {  # <pid-list> <pid>
  local list=$1 target=$2 item
  while IFS= read -r item; do
    [ "$item" = "$target" ] && return 0
  done <<< "$list"
  return 1
}

fm_process_snapshot_uid_for_pid() {  # <pid>
  local target=$1 pid ppid uid state identity
  FM_PROCESS_MATCH_UID=
  FM_PROCESS_MATCH_IDENTITY=
  while IFS=$'\t' read -r pid ppid uid state identity; do
    [ -n "$pid" ] || continue
    if [ "$pid" = "$target" ]; then
      FM_PROCESS_MATCH_UID=$uid
      FM_PROCESS_MATCH_IDENTITY=$identity
      return 0
    fi
  done <<< "$FM_PROCESS_SNAPSHOT"
  return 1
}

fm_process_proc_uid() {  # <pid>
  local pid=$1 proc_root key real_uid rest
  FM_PROCESS_PROC_UID=
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/status" ]; then
    while IFS=$'\t ' read -r key real_uid rest; do
      [ "$key" = Uid: ] || continue
      case "$real_uid" in ''|*[!0-9]*) return 1 ;; esac
      FM_PROCESS_PROC_UID=$real_uid
      return 0
    done < "$proc_root/$pid/status"
  fi
  real_uid=$(stat -Lc '%u' "$proc_root/$pid" 2>/dev/null) || return 1
  case "$real_uid" in ''|*[!0-9]*) return 1 ;; esac
  FM_PROCESS_PROC_UID=$real_uid
}

# /proc is the sole birth-identity authority, exactly as it is the sole coverage
# authority. There is deliberately no `ps -o lstart` fallback: lstart resolves
# only to the second, so it cannot distinguish a PID reused within that second
# from the process we bound, which is precisely the recycled-PID adoption this
# library exists to refuse. A second identity source with weaker guarantees is a
# second way to be wrong. When /proc cannot supply the birth identity of a live
# process, callers refuse and name the pid rather than signal on a weaker check.
# Read birth identity AND run state from ONE /proc/<pid>/stat record, so the two
# can never describe different processes. Taking the state from a separate `ps`
# after the identity read is a second observation with its own window: the bound
# process can exit between the two, and an empty `ps` result would then be read
# as a live match and signaled. One record, one truth.
fm_process_stat_record() {  # <pid>
  local pid=$1 proc_root stat_line
  local -a stat_fields
  FM_PROCESS_STAT_PPID=
  FM_PROCESS_STAT_STATE=
  FM_PROCESS_STAT_STARTTIME=
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  [ -r "$proc_root/$pid/stat" ] || return 1
  stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
  read -r -a stat_fields <<< "${stat_line##*)}"
  [ "${#stat_fields[@]}" -ge 20 ] || return 1
  FM_PROCESS_STAT_STATE=${stat_fields[0]}
  FM_PROCESS_STAT_PPID=${stat_fields[1]}
  FM_PROCESS_STAT_STARTTIME=${stat_fields[19]}
  [ -n "$FM_PROCESS_STAT_STATE" ] || return 1
  case "$FM_PROCESS_STAT_PPID" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_PROCESS_STAT_STARTTIME" in ''|*[!0-9]*) return 1 ;; esac
}

fm_process_identity() {  # <pid>
  fm_process_stat_record "$1" || return 1
  printf 'starttime=%s\n' "$FM_PROCESS_STAT_STARTTIME"
}

fm_process_identity_matches() {  # <pid> <identity>
  local current
  current=$(fm_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}

fm_process_record_status() {  # <pid> <identity>
  FM_PROCESS_RECORD_STATUS=
  if fm_process_stat_record "$1"; then
    if [ "starttime=$FM_PROCESS_STAT_STARTTIME" != "$2" ]; then
      FM_PROCESS_RECORD_STATUS=replaced
      return 0
    fi
    case "$FM_PROCESS_STAT_STATE" in
      Z*) FM_PROCESS_RECORD_STATUS=non-live ;;
      *) FM_PROCESS_RECORD_STATUS=matching ;;
    esac
    return 0
  fi
  if kill -0 "$1" 2>/dev/null; then
    FM_PROCESS_RECORD_STATUS=unknown
    return 1
  fi
  FM_PROCESS_RECORD_STATUS=gone
}

fm_process_require_matching_record() {  # <pid> <identity> <context>
  local pid=$1 identity=$2 context=$3
  if fm_process_record_status "$pid" "$identity"; then
    case "$FM_PROCESS_RECORD_STATUS" in
      matching) return 0 ;;
      gone|replaced|non-live) return 2 ;;
    esac
  fi
  fm_process_error "cannot bind process identity for live $context pid $pid"
  return 1
}

fm_process_record_identity_in_list() {  # <records> <pid>
  local records=$1 target=$2 pid identity
  FM_PROCESS_FOUND_IDENTITY=
  while IFS=$'\t' read -r pid identity; do
    [ -n "$pid" ] || continue
    if [ "$pid" = "$target" ]; then
      FM_PROCESS_FOUND_IDENTITY=$identity
      return 0
    fi
  done <<EOF
$records
EOF
  return 1
}

fm_process_merge_records() {  # <retained-records> <scanned-records>
  local retained=$1 scanned=$2 merged='' pid identity
  FM_PROCESS_MERGED_RECORDS=
  FM_PROCESS_RECORD_ERROR_PID=
  while IFS=$'\t' read -r pid identity; do
    [ -n "$pid" ] || continue
    if ! fm_process_record_status "$pid" "$identity"; then
      FM_PROCESS_RECORD_ERROR_PID=$pid
      return 1
    fi
    [ "$FM_PROCESS_RECORD_STATUS" = matching ] || continue
    merged=${merged}${pid}$'\t'${identity}$'\n'
  done <<EOF
$retained
EOF
  while IFS=$'\t' read -r pid identity; do
    [ -n "$pid" ] || continue
    if fm_process_record_identity_in_list "$merged" "$pid"; then
      if [ "$FM_PROCESS_FOUND_IDENTITY" != "$identity" ]; then
        FM_PROCESS_RECORD_ERROR_PID=$pid
        return 1
      fi
      continue
    fi
    if ! fm_process_record_status "$pid" "$identity"; then
      FM_PROCESS_RECORD_ERROR_PID=$pid
      return 1
    fi
    [ "$FM_PROCESS_RECORD_STATUS" = matching ] || continue
    merged=${merged}${pid}$'\t'${identity}$'\n'
  done <<EOF
$scanned
EOF
  FM_PROCESS_MERGED_RECORDS=$merged
}

fm_process_walk_pids_from_records() {  # <records>
  local records=$1 pid identity
  FM_PROCESS_RECORD_PIDS=
  while IFS=$'\t' read -r pid identity; do
    [ -n "$pid" ] || continue
    FM_PROCESS_RECORD_PIDS=${FM_PROCESS_RECORD_PIDS}${pid}$'\n'
  done <<EOF
$records
EOF
}

# Everything an attempt had already bound when a recheck aborted it (rc 2), as
# pid<tab>identity records: every supplied bound record, the aborted pid itself
# when it was not yet bound, and every snapshot row reachable from any of them
# by ppid edges. Used only when a recheck aborts an attempt: the aborted
# attempt's descendants may already be reparented by the retry, so the whole
# bound frontier - earlier cwd roots, queued walk nodes, collected records - is
# carried into it as identity-bound walk records and re-verified there like any
# other seed.
fm_process_carry_unstable_records() {  # <bound-records> [aborted-pid]
  local bound=$1 aborted=${2:-} pid ppid uid state identity current
  local -a frontier
  local frontier_index=0
  local seen='' out=''
  while IFS=$'\t' read -r pid identity; do
    [ -n "$pid" ] || continue
    [ -n "$identity" ] || continue
    fm_process_pid_list_contains "$seen" "$pid" && continue
    seen=${seen}${pid}$'\n'
    out=${out}${pid}$'\t'${identity}$'\n'
    frontier+=("$pid")
  done <<EOF
$bound
EOF
  if [ -n "$aborted" ] && ! fm_process_pid_list_contains "$seen" "$aborted"; then
    while IFS=$'\t' read -r pid ppid uid state identity; do
      [ -n "$pid" ] || continue
      [ "$pid" = "$aborted" ] || continue
      [ -n "$identity" ] || break
      seen=${seen}${pid}$'\n'
      out=${out}${pid}$'\t'${identity}$'\n'
      frontier+=("$pid")
      break
    done <<< "$FM_PROCESS_SNAPSHOT"
  fi
  while [ "$frontier_index" -lt "${#frontier[@]}" ]; do
    current=${frontier[$frontier_index]}
    frontier_index=$((frontier_index + 1))
    while IFS=$'\t' read -r pid ppid uid state identity; do
      [ -n "$pid" ] || continue
      [ "$ppid" = "$current" ] || continue
      case "$state" in
        Z*) continue ;;
      esac
      fm_process_pid_list_contains "$seen" "$pid" && continue
      seen=${seen}${pid}$'\n'
      out=${out}${pid}$'\t'${identity}$'\n'
      frontier+=("$pid")
    done <<< "$FM_PROCESS_SNAPSHOT"
  done
  FM_PROCESS_CANDIDATE_RECORDS=$out
}

fm_process_collect_candidate() {  # <canonical-root>...
  local canonical root_record root pid ppid uid state child identity child_identity
  local queue_record sorted_pids sorted_records rc
  local included='' visited='' roots_text='' records='' bound='' unresolved=''
  local -a roots queue
  local queue_index=0
  roots=()
  queue=()
  FM_PROCESS_CANDIDATE_PIDS=
  FM_PROCESS_CANDIDATE_RECORDS=
  FM_PROCESS_UNCOVERED_PIDS=
  FM_PROCESS_UNSTABLE_RECHECK_PID=
  FM_PROCESS_FAILED_DIR=${1:-}
  fm_process_snapshot || return 1

  for canonical in "$@"; do
    FM_PROCESS_FAILED_DIR=$canonical
    if fm_process_cwd_pids "$canonical"; then
      :
    else
      rc=$?
      if [ "$rc" -eq 2 ]; then
        fm_process_carry_unstable_records "${roots_text}${FM_PROCESS_ROOT_RECORDS}${bound}" "${FM_PROCESS_UNSTABLE_RECHECK_PID:-}"
      fi
      return "$rc"
    fi
    roots_text=${roots_text}${FM_PROCESS_ROOT_RECORDS}
  done

  while IFS=$'\t' read -r root identity; do
    [ -n "$root" ] || continue
    roots+=("$root"$'\t'"$identity")
  done <<< "$roots_text"

  if [ "${#roots[@]}" -gt 0 ]; then
    for root_record in "${roots[@]}"; do
      IFS=$'\t' read -r root identity <<< "$root_record"
      [ "$root" != "${FM_PROCESS_EXCLUDE_PID:-}" ] || continue
      if ! fm_process_snapshot_uid_for_pid "$root"; then
        fm_process_error "cwd root pid $root disappeared from its identity-bound snapshot"
        return 1
      fi
      if [ "$FM_PROCESS_MATCH_UID" != "$FM_PROCESS_CURRENT_UID" ]; then
        fm_process_error "cwd root pid $root is not owned by the current user"
        return 1
      fi
      if [ "$FM_PROCESS_MATCH_IDENTITY" != "$identity" ]; then
        fm_process_error "cwd root pid $root changed identity during discovery"
        return 1
      fi
      fm_process_pid_list_contains "$included" "$root" && continue
      bound=${bound}${root}$'\t'${identity}$'\n'
      included=${included}${root}$'\n'
      records=${records}${root}$'\t'${identity}$'\n'
      visited=${visited}${root}$'\n'
      queue+=("$root"$'\t'"$identity")
    done
  fi

  while IFS=$'\t' read -r root identity; do
    [ -n "$root" ] || continue
    [ "$root" != "${FM_PROCESS_EXCLUDE_PID:-}" ] || continue
    fm_process_pid_list_contains "$visited" "$root" && continue
    if ! fm_process_snapshot_uid_for_pid "$root"; then
      continue
    fi
    [ "$FM_PROCESS_MATCH_UID" = "$FM_PROCESS_CURRENT_UID" ] || continue
    [ -n "$identity" ] || continue
    [ "$FM_PROCESS_MATCH_IDENTITY" = "$identity" ] || continue
    if fm_process_record_status "$root" "$identity"; then
      [ "$FM_PROCESS_RECORD_STATUS" = matching ] || continue
    else
      fm_process_error "cannot bind process identity for live retained walk pid $root"
      return 1
    fi
    visited=${visited}${root}$'\n'
    queue+=("$root"$'\t'"$identity")
    bound=${bound}${root}$'\t'${identity}$'\n'
    fm_process_pid_list_contains "$included" "$root" && continue
    included=${included}${root}$'\n'
    records=${records}${root}$'\t'${identity}$'\n'
  done <<< "${FM_PROCESS_WALK_RECORDS:-}"

  while [ "$queue_index" -lt "${#queue[@]}" ]; do
    queue_record=${queue[$queue_index]}
    queue_index=$((queue_index + 1))
    IFS=$'\t' read -r pid identity <<< "$queue_record"
    if fm_process_require_matching_record "$pid" "$identity" "walk"; then
      :
    else
      rc=$?
      if [ "$rc" -eq 2 ]; then
        fm_process_carry_unstable_records "${roots_text}${bound}" "$pid"
      fi
      return "$rc"
    fi
    while IFS=$'\t' read -r child ppid uid state child_identity; do
      [ -n "$child" ] || continue
      [ "$ppid" = "$pid" ] || continue
      case "$state" in Z*) continue ;; esac
      [ "$child" != "${FM_PROCESS_EXCLUDE_PID:-}" ] || continue
      fm_process_pid_list_contains "$visited" "$child" && continue
      visited=${visited}${child}$'\n'
      [ -n "$child_identity" ] || {
        fm_process_error "descendant pid $child has no birth identity"
        return 1
      }
      if fm_process_require_matching_record "$child" "$child_identity" "descendant"; then
        :
      else
        rc=$?
        if [ "$rc" -eq 2 ]; then
          fm_process_carry_unstable_records "${roots_text}${bound}" "$child"
        fi
        return "$rc"
      fi
      bound=${bound}${child}$'\t'${child_identity}$'\n'
      queue+=("$child"$'\t'"$child_identity")
      if [ "$uid" != "$FM_PROCESS_CURRENT_UID" ]; then
        continue
      fi
      included=${included}${child}$'\n'
      records=${records}${child}$'\t'${child_identity}$'\n'
    done <<< "$FM_PROCESS_SNAPSHOT"
  done

  # An unreadable-cwd pid that the ancestry walk reached IS covered: ancestry
  # never needed its cwd, its birth identity is bound, and it is signaled like
  # any other record. Only the ones still outside the owned tree remain unknown,
  # and those are what get disclosed to the operator.
  if [ -n "$FM_PROCESS_UNCOVERED_PIDS" ]; then
    unresolved=''
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      fm_process_pid_list_contains "$included" "$pid" && continue
      unresolved=${unresolved}${pid}$'\n'
    done <<< "$FM_PROCESS_UNCOVERED_PIDS"
    FM_PROCESS_UNCOVERED_PIDS=$(printf '%s' "$unresolved" | sort -un)
  fi

  sorted_records=$(printf '%s' "$records" | sort -un -k1,1)
  fm_process_walk_pids_from_records "$sorted_records"
  sorted_pids=$FM_PROCESS_RECORD_PIDS
  FM_PROCESS_CANDIDATE_PIDS=$sorted_pids
  FM_PROCESS_CANDIDATE_RECORDS=$sorted_records
}

fm_process_pids_under_roots() {  # <dir>...
  local dir canonical previous_records='' candidate_records='' retained_records='' carried_records='' attempt=1 rc
  local saved_walk=${FM_PROCESS_WALK_RECORDS:-}
  local -a canonical_roots
  canonical_roots=()
  FM_PROCESS_PIDS=
  FM_PROCESS_RECORDS=
  FM_PROCESS_FAILED_DIR=
  FM_PROCESS_ENUMERATOR=
  FM_PROCESS_ENUMERATION_ERROR=

  for dir in "$@"; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    canonical=$(cd "$dir" 2>/dev/null && pwd -P) || {
      FM_PROCESS_FAILED_DIR=$dir
      fm_process_error "cannot canonicalize process root $dir"
      return 1
    }
    canonical_roots+=("$canonical")
  done

  [ "${#canonical_roots[@]}" -gt 0 ] || return 0
  while [ "$attempt" -le 4 ]; do
    FM_PROCESS_WALK_RECORDS=${saved_walk}${retained_records}${carried_records}
    if fm_process_collect_candidate "${canonical_roots[@]}"; then
      FM_PROCESS_WALK_RECORDS=$saved_walk
      candidate_records=$FM_PROCESS_CANDIDATE_RECORDS
      if ! fm_process_merge_records "$retained_records" "$candidate_records"; then
        FM_PROCESS_FAILED_DIR=${canonical_roots[0]}
        fm_process_error "cannot verify retained process ${FM_PROCESS_RECORD_ERROR_PID:-<unknown>} identity"
        return 1
      fi
      retained_records=$FM_PROCESS_MERGED_RECORDS
      carried_records=''
      if [ "$attempt" -gt 1 ] && [ "$retained_records" = "$previous_records" ]; then
        fm_process_walk_pids_from_records "$retained_records"
        FM_PROCESS_PIDS=$FM_PROCESS_RECORD_PIDS
        FM_PROCESS_RECORDS=$retained_records
        return 0
      fi
      previous_records=$retained_records
    else
      rc=$?
      FM_PROCESS_WALK_RECORDS=$saved_walk
      [ "$rc" -eq 2 ] || return 1
      carried_records=${carried_records}${FM_PROCESS_CANDIDATE_RECORDS:-}
      previous_records="unstable-attempt-$attempt"
    fi
    attempt=$((attempt + 1))
  done
  FM_PROCESS_FAILED_DIR=${canonical_roots[0]}
  fm_process_error "process tree did not stabilize during enumeration"
}
