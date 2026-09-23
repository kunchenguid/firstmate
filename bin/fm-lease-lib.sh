#!/usr/bin/env bash
# fm-lease-lib.sh - the per-task supervision lease contract (one owner).
#
# WHY. A supervision branch (docs/pi-supervision-branch.md) is a second LLM
# actor beside MAIN (the captain's chat) in one firstmate home - on Pi, a
# persistent conversation inside the same pi process - and nothing in this
# contract assumes the two actors share a process. Most records have exactly
# one natural owner, but the overlap set - steering or stopping a worker,
# post-landing cleanup, backlog status for a task, stuck-worker recovery -
# could otherwise be mutated by both actors at once. The lease is the
# merge-conflict analog: a small per-task file saying which actor is changing
# that task right now, and the mutating entrypoints refuse the other actor
# while it exists.
#
# CONTRACT.
#   - Lease file: $STATE/.lease-<task>, one line "<actor>\t<pid>\t<epoch>".
#     Written atomically (temp + ln for claim, temp + mv for a same-actor
#     refresh), with inspection and mutation serialized by the home-local
#     lease-command lock; leases never coordinate across firstmate homes.
#   - Actors: exactly "main" and "branch". The current actor is
#     $FM_SUPERVISION_ACTOR when set, else "main". The branch's shell gets
#     FM_SUPERVISION_ACTOR=branch injected deterministically by the process
#     hosting it (on Pi, the branch extension's bash tool), not by agent
#     memory. Any other value is refused loudly - an unknown actor is a wiring
#     bug, not a third role.
#   - Staleness: the recorded pid is the long-lived supervising process (the
#     session-lock holder, or FM_LEASE_HOLDER_PID - see bin/fm-lease.sh), so a
#     dead recorded pid means the supervising session died; the lease is
#     cleared at the next claim, guard, or sweep. Liveness is the pure record
#     test, identical in every calling context: the recorded pid is alive and
#     IS the current state/.lock holder. So a lease left by an exited session
#     goes stale for every reader, whichever harness now owns the home, and an
#     unmarked main honors a live branch lease exactly as a Pi main does. The
#     one residual is a recorded pid recycled onto the next session-lock holder
#     itself; the host that owns a branch conversation releases that actor's
#     leases when it activates a new one (the Pi branch extension's
#     generation-activation cleanup), which also recovers a lease held by the
#     live session but an abandoned branch conversation.
#
# THREAT MODEL (deliberate, captain-decided): these guards are
# CONFUSED-AGENT-GRADE, the same grade bin/fm-gate-refuse-lib.sh documents
# for the gate refusal. They stop non-deliberate misuse - the injected actor
# identity, the loud refusals, and the session-bound staleness make every
# accidental cross-actor mutation fail loudly. A deliberately forging shell
# running as the same uid inside the same pi process can evade any in-process
# discriminator (it can rewrite env, spawn fresh shells, and edit state
# files), so adversarial-grade separation is explicitly out of scope here and
# tracked as separate follow-up design work. The branch's shell prelude makes
# the actor variables readonly (see the Pi branch extension), so an
# ACCIDENTAL override fails loudly inside the branch's own shell as well.
#   - Guard semantics (fm_lease_guard): no lease, a same-actor lease, or a
#     provably stale lease passes; a live lease held by the OTHER actor
#     refuses with exit FM_LEASE_REFUSE_EXIT. Whenever the guard engages - a
#     supervision context (Pi, or an explicit actor) or any lease file for the
#     task - it retains the lease-command lock until fm_lease_guard_release,
#     so the other actor cannot claim between the check and the guarded
#     mutation. An unmarked caller with no lease file for the task returns
#     before taking any lock, so a home that never ran a branch is unchanged
#     byte for byte; that caller does not exclude a claim that starts during
#     its mutation.
#   - Role partition (fm_lease_forbid_branch): actions MAIN alone owns -
#     merging a PR, landing local-only work, spawning workers, answering a
#     decision - refuse the branch actor outright, lease or no lease, while
#     the home is attended. While a confirmed, readable, live away-posture
#     record exists (bin/fm-afk-contract.sh validate; docs/pi-supervision-
#     branch.md "Postures"), main is parked and its STANDING authority
#     relocates to the branch for exactly the actions whose guarded script
#     opts in with --away-relocated: a PR merge, a fresh spawn of queued work,
#     and a decision answer. Each guarded script keeps its own mechanical gate;
#     bin/fm-branch-prompt.sh "Postures" owns how the branch judges the
#     captain's away words before invoking one. The
#     relocation grants nothing beyond what main could do attended: it only
#     changes which actor may reach the guarded script's own gate. An action
#     that has no record-side gate of its own - landing local-only work - is
#     never relocated and keeps refusing the branch in both postures. An
#     archived, absent, unconfirmed, or unreadable record is absence: the
#     attended refusal, byte for byte. The record is validated immediately
#     before the guarded script's first persistent side effect and the lock is
#     not held across the operation, so a return's archive is never blocked by
#     a long spawn; a spawn or answer that completes seconds after archive is
#     standing-authority work the captain had queued anyway (accepted,
#     confused-agent-grade, like the merge residuals fm-pr-merge.sh documents).
#   - "backlog" is a reserved claimable resource name used by the branch
#     prompt around its own data/backlog.md writes. This is deliberately
#     branch-side containment only; main's tasks-axi path has no executable
#     backlog lease guard in this scope.
#
# Sourced by bin/fm-send.sh, bin/fm-control.sh, bin/fm-teardown.sh,
# bin/fm-pr-merge.sh, bin/fm-merge-local.sh, bin/fm-spawn.sh, and
# bin/fm-lease.sh. Callers must have $STATE resolved before calling. No side
# effects on source. set -u / set -e safe.

# Distinct from usage errors (2), the gate refusal (3), and fm-send's
# unconfirmed submit (3): recognizable as "the other supervision actor holds
# this task right now - retry after the lease clears".
FM_LEASE_REFUSE_EXIT=6
FM_LEASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_LEASE_GUARD_LOCK=

fm_lease_lock_helpers() {
  command -v fm_lock_acquire_wait >/dev/null 2>&1 && return 0
  # fm-wake-lib.sh is a canonical lint root in its own right and is already
  # sourced directly by every caller of this lazy fallback; keep this an
  # analysis boundary so ShellCheck's external-source traversal does not
  # recursively duplicate that large graph for every lease-lib consumer.
  # shellcheck source=/dev/null
  . "$FM_LEASE_LIB_DIR/fm-wake-lib.sh"
}

# fm_lease_actor: print the current actor after validating it. Returns 1 (with
# stderr) for an unknown FM_SUPERVISION_ACTOR value.
fm_lease_actor() {
  local actor=${FM_SUPERVISION_ACTOR:-main}
  case "$actor" in
    main|branch) printf '%s\n' "$actor" ;;
    *)
      echo "error: unknown FM_SUPERVISION_ACTOR '$actor' (expected main or branch)" >&2
      return 1
      ;;
  esac
}

# fm_lease_valid_id <id>: 0 iff the task/resource id is safe to embed in a
# state filename.
fm_lease_valid_id() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_lease_path() {
  printf '%s/.lease-%s\n' "$STATE" "$1"
}

# fm_lease_read <task>: read the lease into FM_LEASE_ACTOR/FM_LEASE_PID/
# FM_LEASE_EPOCH. Returns 1 when no lease file exists. A malformed lease
# (unreadable actor or pid) reads as actor "" so callers treat it as stale
# rather than blocking forever on a torn record.
fm_lease_read() {
  local file line
  file=$(fm_lease_path "$1")
  FM_LEASE_ACTOR=
  FM_LEASE_PID=
  FM_LEASE_EPOCH=
  [ -e "$file" ] || return 1
  IFS= read -r line < "$file" 2>/dev/null || line=
  FM_LEASE_ACTOR=$(printf '%s' "$line" | cut -f1)
  FM_LEASE_PID=$(printf '%s' "$line" | cut -f2)
  # shellcheck disable=SC2034 # Consumed by sourcing callers (bin/fm-lease.sh check).
  FM_LEASE_EPOCH=$(printf '%s' "$line" | cut -f3)
  case "$FM_LEASE_ACTOR" in
    main|branch) ;;
    *) FM_LEASE_ACTOR= ;;
  esac
  case "$FM_LEASE_PID" in
    '' | *[!0-9]*) FM_LEASE_PID= ;;
  esac
  return 0
}

# fm_lease_live <task>: 0 iff a well-formed lease exists, its recorded pid is
# alive, and that pid IS the current session-lock holder (the staleness
# contract above). The calling context never enters the verdict.
fm_lease_live() {
  local lock_pid
  fm_lease_read "$1" || return 1
  [ -n "$FM_LEASE_ACTOR" ] || return 1
  [ -n "$FM_LEASE_PID" ] || return 1
  kill -0 "$FM_LEASE_PID" 2>/dev/null || return 1
  lock_pid=$(head -n 1 "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|0|1|*[!0-9]*) return 1 ;; esac
  [ "$FM_LEASE_PID" = "$lock_pid" ]
}

# fm_lease_clear_stale <task>: remove the lease file when it exists but is not
# live. Silent; never touches a live lease.
fm_lease_clear_stale() {
  local file
  file=$(fm_lease_path "$1")
  [ -e "$file" ] || return 0
  fm_lease_live "$1" && return 0
  rm -f -- "$file"
}

# fm_lease_guard <task> <action-label>: refuse (exit FM_LEASE_REFUSE_EXIT) when
# a live lease held by the OTHER actor exists for <task>. Once engaged (the
# guard semantics above), a successful guard retains the command lock across
# the caller's mutation; the caller must invoke fm_lease_guard_release from its
# EXIT cleanup. This closes the check/use race with a concurrent claim.
fm_lease_guard() {
  local task=$1 action=$2 actor lock lease_actor
  fm_lease_valid_id "$task" || return 0
  actor=$(fm_lease_actor) || exit "$FM_LEASE_REFUSE_EXIT"
  case "${PI_CODING_AGENT:-}:${FM_SUPERVISION_ACTOR:-}" in
    true:*|*:main|*:branch) ;;
    *) [ -e "$(fm_lease_path "$task")" ] || return 0 ;;
  esac
  fm_lease_lock_helpers
  lock="$STATE/.fm-lease-command.lock"
  # A caller with more than one guarded phase already excludes claims until
  # its shared cleanup; do not recursively acquire the non-reentrant lock.
  if [ "$FM_LEASE_GUARD_LOCK" != "$lock" ]; then
    fm_lock_acquire_wait "$lock"
    FM_LEASE_GUARD_LOCK=$lock
  fi
  if ! fm_lease_live "$task"; then
    fm_lease_clear_stale "$task" || { fm_lease_guard_release; return 1; }
    return 0
  fi
  lease_actor=$FM_LEASE_ACTOR
  if [ "$lease_actor" != "$actor" ]; then
    fm_lease_guard_release
    echo "error: $action refused - task '$task' is leased to the $lease_actor supervision actor (state/.lease-$task); retry after that actor releases it" >&2
    exit "$FM_LEASE_REFUSE_EXIT"
  fi
}

# Release the claim/guard serialization lock retained by fm_lease_guard.
# Idempotent so callers can use it unconditionally from existing EXIT cleanup.
fm_lease_guard_release() {
  local lock=$FM_LEASE_GUARD_LOCK
  [ -n "$lock" ] || return 0
  FM_LEASE_GUARD_LOCK=
  fm_lock_release "$lock"
}

# fm_lease_away_relocated: 0 iff main's standing authority is relocated to the
# branch actor right now - a confirmed, readable, live away-posture record
# exists in $STATE, as bin/fm-afk-contract.sh's own validate subcommand judges
# it (the header's role-partition paragraph). Read fresh on every call, never
# cached, because the record can be archived between two guarded actions.
fm_lease_away_relocated() {
  [ -f "$STATE/.afk-contract" ] || return 1
  FM_STATE_OVERRIDE="$STATE" "$FM_LEASE_LIB_DIR/fm-afk-contract.sh" validate >/dev/null 2>&1
}

# fm_lease_forbid_branch <action-label> [--away-relocated]: refuse (exit
# FM_LEASE_REFUSE_EXIT) when the current actor is the supervision branch.
# Guards the main-owned role partition; a home with no branch never sets the
# actor and always passes. With --away-relocated, the branch passes instead
# while fm_lease_away_relocated holds (main is parked under the away-posture
# record), and the calling script's own gate decides what may happen next;
# without the flag the action is never relocated in any posture.
fm_lease_forbid_branch() {
  local action=$1 relocatable=${2:-} actor
  actor=$(fm_lease_actor) || exit "$FM_LEASE_REFUSE_EXIT"
  [ "$actor" = branch ] || return 0
  if [ "$relocatable" = --away-relocated ] && fm_lease_away_relocated; then
    echo "note: $action proceeds for the supervision branch under the away-posture record: main is parked and its standing authority is relocated; this script's own gate still applies (docs/pi-supervision-branch.md \"Postures\")" >&2
    return 0
  fi
  echo "error: $action refused - the supervision branch never performs this action; report the outcome and leave it to main (role partition: docs/pi-supervision-branch.md)" >&2
  exit "$FM_LEASE_REFUSE_EXIT"
}
