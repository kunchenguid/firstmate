#!/usr/bin/env bash
# fm-delivery-proof-lib.sh - the ONE owner of the mechanical delivery proof for
# a reported-done ship task.
#
# Why this exists: four measured incidents (two on 2026-08-24, two on 2026-08-25)
# of the done-without-delivery family - a worker appended `done:` to its status
# log while its commits existed only in the task worktree: no branch on origin,
# no PR. Every supervision surface read that self-report unverified
# (bin/fm-crew-state.sh's status-log fallback and the drain's annotations), so a
# bare claim read as green until a hand check before teardown caught it.
#
# What counts as delivery is read from the task's own recorded contract in
# state/<id>.meta, never assumed:
#   mode=no-mistakes|direct-PR  branch fm/<id> exists at the worktree's origin,
#                               OR an open or merged PR has that head branch
#                               (one bounded ls-remote, one bounded gh pr list;
#                               the PR probe runs only when ls-remote found no
#                               branch);
#   mode=local-only             the worktree's checked-out local branch carries
#                               at least one commit of its own beyond its merge
#                               base with the default branch. The anchor is
#                               origin's remote-tracking default when the clone
#                               knows one, else the local default branch: a
#                               guarded local-only landing moves the local
#                               default to the branch tip, but nothing is ever
#                               pushed, so origin's view - the thing local-only
#                               delivery defers - stays put and keeps the landed
#                               branch's own commits countable;
#   anything else               skip: no recorded delivery to prove.
# kind=secondmate and kind=scout tasks record no ship delivery and always skip.
# A detached local-only HEAD means no local branch carries the work and refutes,
# because the local-only brief contract requires exactly that branch.
#
# Verdict protocol - one "<verdict>\t<evidence>" line on stdout:
#   delivered   <what was found where>
#   refuted     <the concrete absence>          exit status 1
#   unverified  <why no answer was obtainable>  a probe that failed, timed out,
#               or had no tooling is NEVER evidence of absence; callers keep
#               today's behavior for it
#   skip        <why no check applies>
# Exit status is 1 only for refuted, 0 otherwise, so callers can use plain
# command substitution plus an explicit status read.
#
# Callers: bin/fm-wake-lib.sh's fm_wake_print_annotations proves a done line
# when bin/fm-wake-drain.sh presents it to supervision (the loud "done
# WIDERLEGT" presentation line lives there), and bin/fm-crew-state.sh's
# status-log fallback refuses to report a refuted done as terminal current
# state. Both reach this proof only on done lines, never per wake.

# Bounded wall-clock seconds for each single probe (ls-remote, gh pr list, one
# local git read). A probe without a deadline could wedge the very supervision
# turn that is trying to present its wakes.
FM_DELIVERY_PROBE_TIMEOUT=${FM_DELIVERY_PROBE_TIMEOUT:-20}
case "$FM_DELIVERY_PROBE_TIMEOUT" in ''|*[!0-9]*) FM_DELIVERY_PROBE_TIMEOUT=20 ;; esac

# fm_run_timed is the repo's one bounded-execution owner (bin/fm-timeout-lib.sh).
# It declares `set -u` for its own hygiene, which a sourced sibling must not
# impose on THIS library's consumers, so the caller's setting is restored around
# the source - the same dance bin/fm-classify-lib.sh performs.
case $- in *u*) _fm_delivery_proof_nounset=on ;; *) _fm_delivery_proof_nounset=off ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
_fm_delivery_proof_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _fm_delivery_proof_lib_dir="."
if [ -f "$_fm_delivery_proof_lib_dir/fm-timeout-lib.sh" ]; then
  . "$_fm_delivery_proof_lib_dir/fm-timeout-lib.sh"
fi
[ "$_fm_delivery_proof_nounset" = on ] || set +u
unset _fm_delivery_proof_nounset

fm_delivery_probe() {  # <command...>
  fm_run_timed "$FM_DELIVERY_PROBE_TIMEOUT" "$@" 2>/dev/null
}

# The home-local state directory, resolved at call time with the same
# precedence bin/fm-wake-lib.sh bakes in at source time.
fm_delivery_state_dir() {
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then printf '%s' "$FM_STATE_OVERRIDE"; return 0; fi
  if [ -n "${STATE:-}" ]; then printf '%s' "$STATE"; return 0; fi
  local root
  root=${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
  printf '%s' "${FM_HOME:-$root}/state"
}

# The default branch name for <repo>, mirroring bin/fm-teardown.sh's rule:
# origin/HEAD symref first, else main, else master; fail when none resolves.
fm_delivery_default_branch() {  # <repo>
  local ref branch
  ref=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=
  if [ -n "$ref" ]; then
    printf '%s' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$1" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
      printf '%s' "$branch"
      return 0
    fi
  done
  return 1
}

# The immovable anchor for the local-only commit count: origin's remote-tracking
# default when the clone has one, else the local default branch. Fails when no
# anchor ref exists at all.
fm_delivery_local_anchor() {  # <worktree> <default-branch-name>
  if git -C "$1" show-ref --verify --quiet "refs/remotes/origin/$2" 2>/dev/null; then
    printf 'refs/remotes/origin/%s' "$2"
    return 0
  fi
  if git -C "$1" show-ref --verify --quiet "refs/heads/$2" 2>/dev/null; then
    printf 'refs/heads/%s' "$2"
    return 0
  fi
  return 1
}

# Remote-mode proof: branch fm/<id> at origin, else an open/merged PR.
fm_delivery_proof_remote() {  # <task-id> <worktree>
  local id=$1 wt=$2 branch out sha
  branch="fm/$id"
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'unverified\tworktree missing\n'
    return 0
  fi
  if out=$(fm_delivery_probe git -C "$wt" ls-remote origin "refs/heads/$branch"); then
    if [ -n "$out" ]; then
      sha=${out%%$'\t'*}
      sha=${sha##* }
      printf 'delivered\tbranch %s exists at origin (%s)\n' "$branch" "${sha:-unknown-sha}"
      return 0
    fi
  else
    # A probe that did not answer cleanly proves nothing about absence.
    printf 'unverified\tls-remote did not answer cleanly\n'
    return 0
  fi
  command -v gh >/dev/null 2>&1 || { printf 'unverified\tgh unavailable for the PR probe\n'; return 0; }
  if out=$(cd "$wt" && fm_delivery_probe gh pr list --state all --head "$branch" --limit 50 --json state); then
    case "$out" in
      *'"OPEN"'*|*'"MERGED"'*)
        printf 'delivered\tPR with head %s is open or merged\n' "$branch"
        return 0
        ;;
    esac
    printf 'refuted\tls-remote leer, kein PR\n'
    return 1
  fi
  printf 'unverified\tPR probe did not answer cleanly\n'
  return 0
}

# Local-only proof: the checked-out local branch carries its own commits.
fm_delivery_proof_local() {  # <task-id> <worktree>
  local id=$1 wt=$2 branch default anchor base count
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'unverified\tworktree missing\n'
    return 0
  fi
  if ! branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    printf 'refuted\tkein lokaler Zweig im Worktree\n'
    return 1
  fi
  if ! default=$(fm_delivery_default_branch "$wt"); then
    printf 'unverified\tdefault branch undeterminable\n'
    return 0
  fi
  if ! anchor=$(fm_delivery_local_anchor "$wt" "$default"); then
    printf 'unverified\tno anchor ref for %s\n' "$default"
    return 0
  fi
  if ! base=$(git -C "$wt" merge-base HEAD "$anchor" 2>/dev/null); then
    printf 'unverified\tmerge base with %s undeterminable\n' "$anchor"
    return 0
  fi
  if ! count=$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null); then
    printf 'unverified\tcommit count undeterminable\n'
    return 0
  fi
  case "$count" in
    ''|*[!0-9]*)
      printf 'unverified\tcommit count undeterminable\n'
      return 0
      ;;
    0)
      printf 'refuted\tleerer Zweig %s im Worktree\n' "$branch"
      return 1
      ;;
    *)
      printf 'delivered\tlocal branch %s carries %s commit(s)\n' "$branch" "$count"
      return 0
      ;;
  esac
}

# The public entry point. See the header for the verdict protocol.
fm_delivery_proof() {  # <task-id>
  local id=$1 meta kind mode wt
  [ -n "$id" ] || { printf 'skip\tno task id given\n'; return 0; }
  meta="$(fm_delivery_state_dir)/$id.meta"
  if [ ! -f "$meta" ]; then
    printf 'skip\tno metadata for %s\n' "$id"
    return 0
  fi
  kind=$(grep "^kind=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2-) || true
  if [ -z "$kind" ]; then
    kind=ship
  fi
  if [ "$kind" != ship ]; then
    printf 'skip\tkind=%s records no ship delivery\n' "$kind"
    return 0
  fi
  mode=$(grep "^mode=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2-) || true
  case "$mode" in
    no-mistakes|direct-PR)
      wt=$(grep "^worktree=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2-) || true
      fm_delivery_proof_remote "$id" "$wt"
      ;;
    local-only)
      wt=$(grep "^worktree=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2-) || true
      fm_delivery_proof_local "$id" "$wt"
      ;;
    '')
      printf 'skip\tno recorded delivery mode\n'
      ;;
    *)
      printf 'skip\tunknown delivery mode %s\n' "$mode"
      ;;
  esac
}
