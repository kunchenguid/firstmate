#!/usr/bin/env bash
# fm-worktree-guard.sh - choose the pool slot a spawn may be handed, and refuse
# the spawn when every slot the pool would hand out still holds live work.
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
# live process, and a clean working tree. It does NOT consider whether HEAD still
# holds content the default branch never received, so a slot holding a
# finished-but-unlanded branch is allocatable and the next spawn detaches it.
# That is true of EVERY slot in that shape, so a pool holding several parked
# branches reports several available slots, all of them at risk.
#
# WHY IT ALSO SELECTS THE SLOT
# `treehouse get` hands out the first available slot and takes no slot argument,
# so a guard that could only refuse turned one parked slot into a pool-wide
# blockade: genuinely empty slots later in the pool were never reachable, and
# the only way through was authorizing the parked slots by hand. `select`
# therefore names a demonstrably empty slot for the caller to acquire BY NAME
# (`treehouse enter <name>`, which does not reset it), and an occupied slot is
# then simply skipped rather than reset or turned into a refusal.
# The refusal is unchanged where it still matters: with no empty slot to steer
# to, the caller falls back to `treehouse get`, so every available slot must be
# demonstrably empty or explicitly authorized, exactly as before.
#
# WHAT "UNLANDED" MEASURES AGAINST
# bin/fm-landed-lib.sh owns that question and the reasons commit reachability
# and a single remote-tracking ref are both the wrong instrument. This guard's
# own policy on top of it: a slot is empty when ANY ref carrying the default
# branch's name already contains HEAD's content, because containment in any
# trunk proves the content outlives the slot.
# Uncommitted content is separately protected by treehouse itself: it reports
# such a slot "dirty", skips it, and refuses outright rather than reclaiming one
# when every slot is dirty. The exposure this guard closes is therefore
# specifically: clean working tree + commits not reachable from the default
# branch.
#
# WHAT IT DOES NOT DO
# It never resets, cleans, forces, discards, or releases anything. It only names
# a slot, or refuses. bin/fm-teardown.sh remains the sole releaser of work
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
# A RECORDED PID IS THE WEAKEST EVIDENCE, AND ONLY EVIDENCE *FOR* LIVENESS
# The recorded pid is one process sampled when the slot was accepted, so it
# stops matching for reasons that say nothing about the task: a reboot, or the
# sampled process simply exiting while the worker runs on. "Gone" therefore
# needs more than that mismatch. Every stronger binding is checked first, and
# any one of them carries the live verdict on its own: HERDR_PANE_ID in a live
# process's environment matching the task's recorded herdr_pane_id, the
# GOTMPDIR fm-spawn exports into the pane matching its recorded tasktmp, or a
# live process whose cwd is inside the slot. Only when none of them holds does
# a mismatched identity read "dead".
#
# Usage:
#   fm-worktree-guard.sh check <project-dir>
#       Exit 0 when the pool can be allocated from safely: some available slot
#       is demonstrably empty, or every available slot that is not is covered by
#       explicit operator authority. Exit 1 with an actionable per-slot refusal
#       on stderr otherwise.
#   fm-worktree-guard.sh select <project-dir>
#       The same decision as `check`, and on success additionally print
#       "<slot-name><TAB><worktree-path>" for the demonstrably empty slot the
#       caller should acquire by name. Prints nothing when the pool offers no
#       such slot, which leaves the allocation to `treehouse get`.
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
# shellcheck source=bin/fm-landed-lib.sh
. "$FM_GUARD_DIR/fm-landed-lib.sh"

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

# Commits in <worktree> not reachable from <ref>, or "unknown". Used only to
# WORD a refusal that fm_landed_tree_contains has already decided; it is never
# the test itself, because a squash or a rebase leaves this count non-zero long
# after the content landed.
ahead_count() {  # <worktree> <ref>
  git --no-optional-locks -C "$1" rev-list --count "$2..HEAD" 2>/dev/null || echo unknown
}

# Live-work evidence in <worktree>, printed as one short phrase, or non-zero
# when the slot is demonstrably empty. Every git read uses --no-optional-locks
# so inspecting another lane's worktree never writes its index.
#
# Deliberately conservative: anything this cannot positively verify as empty is
# evidence. A false refusal is a loud, actionable stop; a false pass destroys
# work.
worktree_evidence() {  # <worktree>
  local wt=$1 top dirty branch name ref ahead refs contains
  local best_ref='' best_ahead='' first_ref='' proven=1
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
  if ! name=$(fm_landed_default_branch_name "$wt") || ! refs=$(fm_landed_candidate_refs "$wt" "$name"); then
    printf 'no resolvable default branch, so unlanded work cannot be ruled out\n'
    return 0
  fi
  # The slot is demonstrably empty when ANY ref carrying the default-branch name
  # already contains HEAD's content. Testing every candidate rather than one
  # chosen ref is what makes this correct for a fleet whose remote-tracking ref
  # is not the landing target: containment in any trunk proves the content
  # survives this slot, so releasing it loses nothing. It cannot pass unlanded
  # work off a stale ref either - if HEAD carries content no candidate has, no
  # candidate reports it contained.
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    [ -n "$first_ref" ] || first_ref=$ref
    fm_landed_tree_contains "$wt" "$ref"
    contains=$?
    [ "$contains" -eq 0 ] && return 1
    # Only a proven "not contained" may word a refusal about unlanded commits;
    # an inconclusive read still refuses, but says so as unverifiable.
    [ "$contains" -eq 1 ] || continue
    ahead=$(ahead_count "$wt" "$ref")
    # A non-numeric count cannot word a refusal, and a zero count contradicts
    # "not contained"; both fall through to the unverifiable wording.
    case "$ahead" in ''|*[!0-9]*) continue ;; esac
    [ "$ahead" -gt 0 ] || continue
    if [ "$proven" = 1 ] || [ "$ahead" -lt "$best_ahead" ]; then
      best_ref=$ref
      best_ahead=$ahead
      proven=0
    fi
  done <<EOF
$refs
EOF
  if [ "$proven" != 0 ]; then
    printf 'HEAD cannot be compared against %s\n' "${first_ref#refs/}"
    return 0
  fi
  branch=$(git --no-optional-locks -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  local noun=commits
  [ "$best_ahead" = 1 ] && noun=commit
  if [ -n "$branch" ]; then
    printf 'branch %s with %s %s not on %s\n' "$branch" "$best_ahead" "$noun" "${best_ref#refs/}"
  else
    printf 'detached HEAD with %s %s not on %s\n' "$best_ahead" "$noun" "${best_ref#refs/}"
  fi
  return 0
}

# The state/<id>.meta of the firstmate task recording <worktree>. Non-zero when
# no task claims it.
claiming_meta() {  # <worktree-real>
  local wt=$1 meta claimed
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    claimed=$(fm_meta_get "$meta" worktree)
    [ -n "$claimed" ] || continue
    [ "$(real_or_raw "$claimed")" = "$wt" ] || continue
    printf '%s\n' "$meta"
    return 0
  done
  return 1
}

# The pid of a live process whose environment contains any of the given exact
# <KEY>=<VALUE> entries, or non-zero when none does.
#
# This is how a task is recognised in a process it never recorded. Herdr injects
# HERDR_PANE_ID into every process it manages a pane for (docs/herdr-backend.md),
# and bin/fm-spawn.sh exports GOTMPDIR into the pane before the agent starts, so
# either entry binds a running process to one task independently of the pid the
# slot recorded. Two independent bindings are read on purpose: a live verdict
# must survive losing one of them, so a backend that supplies no pane id is
# still covered.
#
# Entries are compared whole - never as a prefix - so a longer id that merely
# starts with another task's id can never be mistaken for it.
env_bound_pid() {  # <key=value> [<key=value>...]
  local proc_root dir pid entry binding
  [ $# -gt 0 ] || return 1
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  [ -d "$proc_root" ] || return 1
  for dir in "$proc_root"/[0-9]*; do
    pid=${dir##*/}
    [ "$pid" = "$$" ] && continue
    [ -r "$dir/environ" ] || continue
    # A process that exits between the readability test and the open is not an
    # error, just one fewer candidate.
    { exec 3< "$dir/environ"; } 2>/dev/null || continue
    while IFS= read -r -d '' entry <&3 || [ -n "$entry" ]; do
      for binding in "$@"; do
        if [ "$entry" = "$binding" ]; then
          exec 3<&-
          printf '%s\n' "$pid"
          return 0
        fi
      done
      entry=
    done
    exec 3<&-
  done
  return 1
}

# How the apparent owner of <worktree-real> resolves, as
# "<state>\t<id>\t<detail>": alive / dead / unresolved / unclaimed.
#
# Live evidence is read strongest-first, and any one source is enough, because
# each is independently sufficient and none of them is available on every
# backend. Only a recorded identity that no longer matches AND no live evidence
# at all reads dead; a record that was never written reads unresolved. So a
# missing record can never be mistaken for a released slot, and a live worker
# can never be reported as an orphan on the strength of a stale pid alone.
resolve_owner() {  # <worktree-real>
  local wt=$1 meta id pid identity current pane tasktmp
  local -a bindings=()
  if ! meta=$(claiming_meta "$wt"); then
    printf 'unclaimed\t\t\n'
    return 0
  fi
  id=$(basename "$meta" .meta)
  pid=$(fm_meta_get "$meta" worktree_owner_pid)
  identity=$(fm_meta_get "$meta" worktree_owner_identity)
  if [ -n "$pid" ] && [ -n "$identity" ] \
    && current=$(fm_pid_identity "$pid" 2>/dev/null) && [ "$current" = "$identity" ]; then
    printf 'alive\t%s\tprocess identity verified\n' "$id"
    return 0
  fi
  pane=$(fm_meta_get "$meta" herdr_pane_id)
  [ -z "$pane" ] || bindings+=("HERDR_PANE_ID=$pane")
  tasktmp=$(fm_meta_get "$meta" tasktmp)
  [ -z "$tasktmp" ] || bindings+=("GOTMPDIR=$tasktmp/gotmp")
  if [ "${#bindings[@]}" -gt 0 ] && env_bound_pid "${bindings[@]}" >/dev/null; then
    printf 'alive\t%s\tits worker process is still running\n' "$id"
    return 0
  fi
  if occupant_pid "$wt" >/dev/null; then
    printf 'alive\t%s\tprocesses are still running in it\n' "$id"
    return 0
  fi
  if [ -z "$pid" ] || [ -z "$identity" ]; then
    printf 'unresolved\t%s\t\n' "$id"
    return 0
  fi
  printf 'dead\t%s\t\n' "$id"
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

# Whether a demonstrably empty <worktree> is also in the shape allocation may
# steer to by name. `treehouse enter` does not reset the slot, so the slot must
# already be parked where `treehouse get` would have left it: a detached HEAD or
# the default branch, never a task branch. A slot whose directory is gone is
# empty but cannot be entered by name at all; `treehouse get` recreates it, so
# it is left to that path rather than selected.
slot_parked_shape() {  # <slot-name> <worktree-real>
  local name=$1 wt=$2 branch default
  # The name is acquired by being typed into a shell, so only treehouse's own
  # plain slot names are ever selected. Anything else is left to `treehouse get`
  # rather than quoted through: this is a name that came from parsed output.
  case "$name" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ -d "$wt" ] || return 1
  branch=$(git --no-optional-locks -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] || return 0
  default=$(fm_landed_default_branch_name "$wt") || return 1
  [ "$branch" = "$default" ]
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

# The refusal block for one occupied slot, as it is printed to stderr.
slot_refusal_block() {  # <name> <worktree-real> <evidence>
  local name=$1 wt=$2 evidence=$3 owner ostate oid odetail
  owner=$(resolve_owner "$wt")
  ostate=${owner%%$'\t'*}
  owner=${owner#*$'\t'}
  oid=${owner%%$'\t'*}
  odetail=${owner#*$'\t'}
  printf '  slot %s: %s\n' "$name" "$wt"
  printf '    found: %s\n' "$evidence"
  case "$ostate" in
    alive)
      printf '    owner: task %s is still working here (%s)\n' "$oid" "$odetail"
      printf '    to release: let %s finish, or tear it down with bin/fm-teardown.sh %s\n' "$oid" "$oid"
      ;;
    dead)
      printf '    owner: task %s recorded this slot; its worker is gone (recorded process identity no longer matches, and nothing is running for it)\n' "$oid"
      printf '    to release: land or discard %s'"'"'s work, then bin/fm-teardown.sh %s\n' "$oid" "$oid"
      ;;
    unresolved)
      printf '    owner: task %s recorded this slot, but no process identity was recorded, so ownership is unresolved\n' "$oid"
      printf '    to release: reconcile %s, then bin/fm-teardown.sh %s\n' "$oid" "$oid"
      ;;
    *)
      printf '    owner: no firstmate task records this slot\n'
      printf "    to release: confirm the work is landed or saved, then return the slot with 'treehouse return %s'\n" "$wt"
      ;;
  esac
}

# The pool decision, shared by `check` and `select` so the policy has one owner.
# With <mode> = select, the chosen slot is printed to stdout.
cmd_pool() {  # <mode> <project-dir>
  local mode proj proj_real raw total rows refusals=0 name path wt evidence
  local chosen='' report='' authorized=''

  mode=$1
  shift
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
    # Every slot is inspected before anything is reported: an occupied slot is
    # only a refusal if no empty slot is found anywhere in the pool, and pool
    # order decides nothing.
    if ! evidence=$(worktree_evidence "$wt"); then
      if [ -z "$chosen" ] && slot_parked_shape "$name" "$wt"; then
        chosen=$(printf '%s\t%s' "$name" "$wt")
      fi
      continue
    fi
    if reclaim_authorized "$wt"; then
      authorized="$authorized""worktree guard: reclaiming slot $name ($wt) under explicit operator authority despite $evidence"$'\n'
      continue
    fi
    refusals=$((refusals + 1))
    report="$report$(slot_refusal_block "$name" "$wt" "$evidence")"$'\n'
  done <<EOF
$rows
EOF

  # An empty slot is acquired BY NAME, so no other slot is in the allocation's
  # way: an occupied one is skipped untouched rather than reset or refused, and
  # authority no operator had to give is neither needed nor announced.
  if [ -n "$chosen" ]; then
    [ "$mode" = select ] && printf '%s\n' "$chosen"
    return 0
  fi

  # Nothing to steer to, so the caller falls back to `treehouse get`, which
  # hands out the first available slot whatever it holds. Every available slot
  # must therefore be safe to hand out, which is the check this guard has always
  # made.
  [ -z "$authorized" ] || printf '%s' "$authorized" >&2
  if [ "$refusals" -ne 0 ]; then
    {
      echo "error: refusing to spawn - every pool slot treehouse would hand out still holds live work."
      printf '%s' "$report"
      echo "    Nothing was reset, cleaned, or discarded. This spawn simply did not run."
      echo "    Authorize one exact slot with FM_WORKTREE_RECLAIM_OK=<worktree-path> only after its work is safe."
    } >&2
    return 1
  fi
  return 0
}

case "${1:-}" in
  check) shift; cmd_pool check "$@" ;;
  select) shift; cmd_pool select "$@" ;;
  owner-fields) shift; cmd_owner_fields "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
