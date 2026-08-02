#!/usr/bin/env bash
# fm-worktree-guard.sh - refuse a spawn that would be handed a pool slot which
# still holds live work.
#
# WHY THIS RUNS BEFORE `treehouse get`, NOT AFTER
# `treehouse get` resets the slot as part of ACQUIRING it, before it returns the
# path ("Unlike 'get', enter does not acquire, reset, or return the worktree" -
# treehouse's own help). bin/fm-spawn.sh only learns the path by polling the
# pane's cwd, which changes after that reset. A check placed at the point the
# path becomes known therefore inspects a slot whose evidence has already been
# erased - HEAD detached at the default branch, working tree clean - and passes
# every time. So this guard runs before the allocation, over the slots treehouse
# itself reports allocatable.
#
# WHAT IT CATCHES
# `treehouse status --json` reports a slot "available" when it has no lease, no
# live process, and a clean working tree. It does NOT consider whether HEAD carries
# commits unreachable from the default branch, so a slot holding a
# finished-but-unlanded branch is allocatable and the next spawn detaches it.
# Uncommitted content is separately protected by treehouse itself: it reports
# such a slot "dirty", skips it, and refuses outright rather than reclaiming one
# when every slot is dirty. The exposure this guard closes is therefore
# specifically: clean working tree + commits not reachable from the default
# branch.
#
# WHAT IT DOES NOT DO
# It never resets, cleans, forces, discards, or releases anything. It only
# refuses. bin/fm-teardown.sh remains the sole releaser of a slot holding work
# and owns the complete landed-work test; this guard deliberately asks the
# strictly weaker, offline question "is this slot demonstrably empty?" and so
# never restates or weakens that contract.
#
# OWNERSHIP IS AN IDENTITY, NEVER A BARE PID
# After a reboot the kernel reissues pid numbers, so a recorded pre-reboot pid
# often resolves to an unrelated live process and reads as falsely alive.
# Ownership is resolved through fm_pid_identity (bin/fm-wake-lib.sh), which
# combines /proc stat field 22 (boot-relative starttime) with the full cmdline.
# An ABSENT identity reads UNRESOLVED, never "dead".
#
# Usage:
#   fm-worktree-guard.sh check <project-dir>
#       Exit 0 when every slot treehouse would allocate is demonstrably empty.
#       Exit 1 with an actionable refusal on stderr otherwise.
#   fm-worktree-guard.sh owner-fields <worktree>
#       Print the worktree_owner_pid= and worktree_owner_identity= meta lines
#       for an accepted worktree. Both values are empty when no occupant is
#       resolvable, which reads UNRESOLVED at check time.
#
# FM_WORKTREE_RECLAIM_OK=<path>[:<path>...] is explicit operator authority for
# exactly the listed worktree paths. It is path-scoped on purpose so it cannot
# become a standing blanket bypass.
set -u

FM_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_GUARD_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_GUARD_DIR/fm-backend.sh"

usage() {
  awk '/^# Usage:/ { on = 1 } on { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' \
    "${BASH_SOURCE[0]:-$0}"
}

real_or_raw() {  # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# The default-branch ref to measure reachability against, preferring the remote
# tracking ref so a stale local branch cannot make unlanded work look landed.
# Non-zero when no default ref resolves, which the caller treats as evidence
# (unverifiable, so not demonstrably empty) rather than guessing.
default_ref() {  # <worktree>
  local wt=$1 ref branch
  ref=$(git --no-optional-locks -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ] && git --no-optional-locks -C "$wt" rev-parse --verify --quiet "refs/remotes/$ref" >/dev/null 2>&1; then
    printf 'refs/remotes/%s\n' "$ref"
    return 0
  fi
  for branch in main master; do
    if git --no-optional-locks -C "$wt" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
      printf 'refs/remotes/origin/%s\n' "$branch"
      return 0
    fi
    if git --no-optional-locks -C "$wt" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
      printf 'refs/heads/%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# Live-work evidence in <worktree>, printed as one short phrase, or non-zero
# when the slot is demonstrably empty. Every git read uses --no-optional-locks
# so inspecting another lane's worktree never writes its index.
#
# Deliberately conservative: anything this cannot positively verify as empty is
# evidence. A false refusal is a loud, actionable stop; a false pass destroys
# work.
worktree_evidence() {  # <worktree>
  local wt=$1 top dirty branch ref ahead
  # A slot treehouse lists but whose directory is gone has nothing to lose:
  # treehouse recreates it on acquire.
  [ -e "$wt" ] || return 1
  top=$(git --no-optional-locks -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -z "$top" ] || [ "$(real_or_raw "$top")" != "$(real_or_raw "$wt")" ]; then
    printf 'not a readable git worktree, so its contents cannot be verified\n'
    return 0
  fi
  dirty=$(git --no-optional-locks -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ -n "$dirty" ] && [ "$dirty" != 0 ]; then
    printf '%s uncommitted or untracked entries\n' "$dirty"
    return 0
  fi
  if ! ref=$(default_ref "$wt"); then
    printf 'no resolvable default branch, so unlanded work cannot be ruled out\n'
    return 0
  fi
  branch=$(git --no-optional-locks -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  ahead=$(git --no-optional-locks -C "$wt" rev-list --count "$ref..HEAD" 2>/dev/null || echo unknown)
  case "$ahead" in
    ''|*[!0-9]*)
      printf 'HEAD cannot be compared against %s\n' "${ref#refs/}"
      return 0
      ;;
  esac
  if [ "$ahead" != 0 ]; then
    local noun=commits
    [ "$ahead" = 1 ] && noun=commit
    if [ -n "$branch" ]; then
      printf 'branch %s with %s %s not on %s\n' "$branch" "$ahead" "$noun" "${ref#refs/}"
    else
      printf 'detached HEAD with %s %s not on %s\n' "$ahead" "$noun" "${ref#refs/}"
    fi
    return 0
  fi
  return 1
}

# The firstmate task recording <worktree>, as "<id> <pid> <identity>" with the
# pid/identity fields possibly empty. Non-zero when no task claims it.
claiming_task() {  # <worktree-real>
  local wt=$1 meta id claimed
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    claimed=$(fm_meta_get "$meta" worktree)
    [ -n "$claimed" ] || continue
    [ "$(real_or_raw "$claimed")" = "$wt" ] || continue
    id=$(basename "$meta" .meta)
    printf '%s\t%s\t%s\n' \
      "$id" \
      "$(fm_meta_get "$meta" worktree_owner_pid)" \
      "$(fm_meta_get "$meta" worktree_owner_identity)"
    return 0
  done
  return 1
}

# How the apparent owner of <worktree-real> resolves, as "<state>\t<detail>":
# alive / dead / unresolved / unclaimed. Only an identity match reads alive and
# only a recorded identity that no longer matches reads dead; everything else is
# unresolved, so a missing record can never be mistaken for a released slot.
resolve_owner() {  # <worktree-real>
  local wt=$1 row id pid identity current
  if ! row=$(claiming_task "$wt"); then
    printf 'unclaimed\t\n'
    return 0
  fi
  id=${row%%$'\t'*}
  row=${row#*$'\t'}
  pid=${row%%$'\t'*}
  identity=${row#*$'\t'}
  if [ -z "$pid" ] || [ -z "$identity" ]; then
    printf 'unresolved\t%s\n' "$id"
    return 0
  fi
  if current=$(fm_pid_identity "$pid" 2>/dev/null) && [ "$current" = "$identity" ]; then
    printf 'alive\t%s\n' "$id"
  else
    printf 'dead\t%s\n' "$id"
  fi
}

reclaim_authorized() {  # <worktree-real>
  local wt=$1 entry
  local IFS=:
  for entry in ${FM_WORKTREE_RECLAIM_OK:-}; do
    [ -n "$entry" ] || continue
    [ "$(real_or_raw "$entry")" = "$wt" ] && return 0
  done
  return 1
}

# The numerically smallest pid whose cwd sits inside <worktree>. That biases
# toward the earliest-started occupant (the pane's shell), whose exit is the
# durable signal that the task is gone. Any occupant would do: a wrong pick can
# only read dead early, which still refuses, never passes.
occupant_pid() {  # <worktree-real>
  local wt=$1 proc_root dir pid cwd best=
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  [ -d "$proc_root" ] || return 1
  for dir in "$proc_root"/[0-9]*; do
    [ -d "$dir" ] || continue
    pid=${dir##*/}
    [ "$pid" = "$$" ] && continue
    cwd=$(readlink "$dir/cwd" 2>/dev/null) || continue
    case "$cwd" in
      "$wt"|"$wt"/*) ;;
      *) continue ;;
    esac
    if [ -z "$best" ] || [ "$pid" -lt "$best" ]; then
      best=$pid
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

cmd_owner_fields() {  # <worktree>
  local wt pid identity=
  [ $# -eq 1 ] || { usage >&2; return 2; }
  wt=$(real_or_raw "$1")
  if pid=$(occupant_pid "$wt"); then
    identity=$(fm_pid_identity "$pid" 2>/dev/null) || identity=
  else
    pid=
  fi
  [ -n "$identity" ] || pid=
  printf 'worktree_owner_pid=%s\n' "$pid"
  printf 'worktree_owner_identity=%s\n' "$identity"
}

# Available slots as "<name>\t<absolute-path>" rows read from the human-readable
# `treehouse status` table, for builds older than v2.1.0 that have no --json.
# That table needs two compensations the machine format does not: a path under
# $HOME is printed abbreviated with a leading `~`, and a slot may be followed by
# INDENTED per-slot process continuation lines.
#
# Fail-closed: every non-blank, non-indented line must parse as a slot row.
# Skipping an unparseable row would silently yield fewer slots to inspect, which
# is the same fail-open shape as dropping an entry with no `.status`.
plain_available_rows() {  # <project-dir>
  local proj=$1 raw line name status path rest tilde='~'
  if ! raw=$(cd "$proj" && treehouse status 2>/dev/null); then
    echo "error: worktree guard cannot verify pool safety: 'treehouse status' failed in $proj." >&2
    echo "       Refusing rather than allocating blind." >&2
    return 1
  fi
  # An empty pool prints nothing in this format (the JSON format prints []).
  [ -n "$raw" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in [[:space:]]*) continue ;; esac
    read -r name status path rest <<INNER
$line
INNER
    [ -z "$rest" ] || path="$path $rest"
    # A literal tilde, held in a variable so it reads as the abbreviation
    # treehouse printed rather than as a path this shell should expand.
    case "$path" in
      "$tilde"/*)
        if [ -z "${HOME:-}" ]; then
          echo "error: worktree guard read a \$HOME-abbreviated slot path ('$path') but HOME is unset, in $proj." >&2
          echo "       Refusing rather than allocating blind." >&2
          return 1
        fi
        path="$HOME/${path#"$tilde"/}"
        ;;
      /*) ;;
      *)
        echo "error: worktree guard could not parse a 'treehouse status' row ('$line') in $proj." >&2
        echo "       The output format may have changed; refusing rather than allocating blind." >&2
        return 1
        ;;
    esac
    if [ -z "$name" ] || [ -z "$status" ]; then
      echo "error: worktree guard read a 'treehouse status' row with no slot name or status ('$line') in $proj." >&2
      echo "       The output format may have changed; refusing rather than allocating blind." >&2
      return 1
    fi
    [ "$status" = available ] || continue
    printf '%s\t%s\n' "$name" "$path"
  done <<OUTER
$raw
OUTER
}

cmd_check() {  # <project-dir>
  local proj proj_real raw total rows refusals=0 name path wt evidence owner ostate oid

  [ $# -eq 1 ] || { usage >&2; return 2; }
  proj=$1
  if ! proj_real=$(cd "$proj" 2>/dev/null && pwd -P); then
    echo "error: worktree guard cannot read project directory '$proj'" >&2
    return 1
  fi
  if ! command -v treehouse >/dev/null 2>&1; then
    echo "error: worktree guard cannot verify pool safety: treehouse is not on PATH." >&2
    echo "       This spawn is about to run 'treehouse get', so refusing rather than allocating blind." >&2
    return 1
  fi
  # Prefer `status --json`: absolute paths and a stable per-slot schema. That
  # flag does not exist before treehouse v2.1.0 (`status --help` advertises no
  # --json, and passing it exits 1 with "unknown flag"), and CI pins v2.0.1, so
  # capability is probed from treehouse's own help rather than assumed or
  # inferred from an error string.
  if (cd "$proj_real" && treehouse status --help 2>/dev/null) | grep -q -- '--json'; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "error: worktree guard cannot verify pool safety: jq is not on PATH." >&2
      echo "       Install jq (brew install jq, or the platform's package manager), then retry." >&2
      return 1
    fi
    if ! raw=$(cd "$proj_real" && treehouse status --json 2>/dev/null); then
      echo "error: worktree guard cannot verify pool safety: 'treehouse status --json' failed in $proj_real." >&2
      echo "       Refusing rather than allocating blind." >&2
      return 1
    fi
    if ! printf '%s' "$raw" | jq -e '
      type == "array" and
      all(.[];
        type == "object" and
        (.name | type == "string" and length > 0) and
        (.status | type == "string" and length > 0) and
        (.path | type == "string" and length > 0)
      )
    ' >/dev/null 2>&1; then
      echo "error: worktree guard could not parse 'treehouse status --json' in $proj_real." >&2
      echo "       The output format may have changed; refusing rather than allocating blind." >&2
      return 1
    fi
    total=$(printf '%s' "$raw" | jq -r 'length')
    # An empty pool is legitimately safe: treehouse creates a fresh slot.
    [ "$total" -eq 0 ] && return 0
    if ! rows=$(printf '%s' "$raw" | jq -r '.[] | select(.status == "available") | [.name, .path] | @tsv' 2>/dev/null); then
      echo "error: worktree guard could not read slot fields from 'treehouse status --json' in $proj_real." >&2
      echo "       The output format may have changed; refusing rather than allocating blind." >&2
      return 1
    fi
  else
    if ! rows=$(plain_available_rows "$proj_real"); then
      return 1
    fi
  fi
  [ -n "$rows" ] || return 0

  while IFS=$'\t' read -r name path; do
    if [ -z "$path" ] || [ "${path#/}" = "$path" ]; then
      echo "error: worktree guard read a non-absolute slot path ('$path') from treehouse in $proj_real." >&2
      echo "       Refusing rather than allocating blind." >&2
      return 1
    fi
    wt=$(real_or_raw "$path")
    evidence=$(worktree_evidence "$wt") || continue
    if reclaim_authorized "$wt"; then
      echo "worktree guard: reclaiming slot $name ($wt) under explicit operator authority despite $evidence" >&2
      continue
    fi
    refusals=$((refusals + 1))
    if [ "$refusals" = 1 ]; then
      echo "error: refusing to spawn - a pool slot treehouse would hand out still holds live work." >&2
    fi
    owner=$(resolve_owner "$wt")
    ostate=${owner%%$'\t'*}
    oid=${owner#*$'\t'}
    echo "  slot $name: $wt" >&2
    echo "    found: $evidence" >&2
    case "$ostate" in
      alive)
        echo "    owner: task $oid is still working here (process identity verified)" >&2
        echo "    to release: let $oid finish, or tear it down with bin/fm-teardown.sh $oid" >&2
        ;;
      dead)
        echo "    owner: task $oid recorded this slot; its worker is gone (recorded process identity no longer matches)" >&2
        echo "    to release: land or discard $oid's work, then bin/fm-teardown.sh $oid" >&2
        ;;
      unresolved)
        echo "    owner: task $oid recorded this slot, but no process identity was recorded, so ownership is unresolved" >&2
        echo "    to release: reconcile $oid, then bin/fm-teardown.sh $oid" >&2
        ;;
      *)
        echo "    owner: no firstmate task records this slot" >&2
        echo "    to release: confirm the work is landed or saved, then return the slot with 'treehouse return $wt'" >&2
        ;;
    esac
  done <<EOF
$rows
EOF

  if [ "$refusals" -ne 0 ]; then
    echo "    Nothing was reset, cleaned, or discarded. This spawn simply did not run." >&2
    echo "    Authorize one exact slot with FM_WORKTREE_RECLAIM_OK=<worktree-path> only after its work is safe." >&2
    return 1
  fi
  return 0
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  owner-fields) shift; cmd_owner_fields "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
