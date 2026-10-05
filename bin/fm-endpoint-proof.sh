#!/usr/bin/env bash
# fm-endpoint-proof.sh - the READ-ONLY report on whether a task's recorded tmux
# endpoint can be proven gone, plus the idempotent backfill that gives an older
# live record the endpoint identity the proof needs.
#
# Usage: fm-endpoint-proof.sh [show] <task-id>
#        fm-endpoint-proof.sh consents <task-id>
#        fm-endpoint-proof.sh backfill (<task-id> | --all)
#
# FM_HOME must name the home that owns the task, exactly as for fm-control.sh.
#
# show (the default) prints one stable `key: value` block and changes nothing:
#   task, backend, endpoint, endpoint-state (the ambient server's reading of the
#   recorded window), identity (complete | legacy | malformed - see
#   bin/fm-endpoint-proof-lib.sh), and verdict:
#     not-needed  the endpoint exists on the server this seat addresses, so
#                 there is nothing to prove; recover it with fm-control.sh.
#     gone        absence is PROVEN from the record's identity; the line
#                 `basis:` says which fact carried it. fm-control.sh <id>
#                 relaunch will rebind the task.
#     unproven    it cannot be proven; `reason:` says why and nothing here
#                 should be worked around.
#   For a LEGACY record (spawned before the identity was recorded) the report
#   also prints the evidence that can still be read - host and boot identity,
#   whether the record predates this boot, the ambient tmux server, every
#   reachable tmux server of this user and whether any holds a window for the
#   task, and the worktree's live processes - with its `consent-digest:`. That
#   digest is NOT proof. It is the value an operator passes back, on the
#   captain's explicit word for this task, as
#     fm-control.sh <id> relaunch --note <text> --legacy-endpoint-consent <digest>
#   to say "I reviewed exactly this evidence and accept the endpoint gone". It
#   verifies only while the evidence is byte-identical, so it cannot be replayed
#   after anything changed, and it is not offered at all while the evidence
#   names a live window or process (`consent: not possible`).
#
# consents prints the consent records fm-control.sh appended to
# state/<id>.endpoint-consent, each with whether its digest still matches the
# evidence it carries, so a recorded consent can be audited later.
#
# backfill records the endpoint identity of a LEGACY tmux task whose window
# exists on the server this seat addresses (found by its exact recorded label,
# whatever the agent in it is doing), so the NEXT loss of its tmux server can be proven
# instead of refused. It appends the identity lines to the task record under the
# task's meta lock by atomic replace, touches nothing else, and is a no-op for a
# record that already carries identity, a missing endpoint, or any other
# backend. Run it while tmux is healthy; --all covers every task in the home.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  die "FM_HOME is not set; fm-endpoint-proof refuses to resolve a task without an explicit firstmate home"
fi
[ -d "$FM_HOME" ] || die "FM_HOME '$FM_HOME' is not a directory"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || die "state dir '$STATE' is missing"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

VERB=show
case "${1:-}" in
  show|consents|backfill)
    VERB=$1
    shift
    ;;
esac

# resolve_task <id>: validate the exact task id and its record, setting META,
# BACKEND and TARGET. Prints the refusal and returns 1 otherwise.
resolve_task() {
  local id=$1
  case "$id" in
    *:*) echo "error: '$id' is an explicit endpoint; pass the exact task id" >&2; return 1 ;;
  esac
  fm_task_id_creation_valid "$id" || { echo "error: '$id' is not a valid task id" >&2; return 1; }
  META="$STATE/$id.meta"
  [ -f "$META" ] || { echo "error: no task '$id' in $STATE" >&2; return 1; }
  if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
    echo "error: task $id is a remotely placed secondmate; its endpoint is not on this host" >&2
    return 1
  fi
  fm_backend_validate_task_endpoint "$META" "$id" || return 1
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  TARGET=$FM_BACKEND_VALIDATED_TARGET
}

do_show() {
  local id=$1 raw absence verdict detail identity evidence digest unmapped rc=0
  resolve_task "$id" || exit 1
  printf 'task: %s\n' "$id"
  printf 'backend: %s\n' "$BACKEND"
  printf 'endpoint: %s\n' "$TARGET"
  if [ "$BACKEND" != tmux ]; then
    printf 'verdict: not-applicable\n'
    printf 'reason: this report covers tmux endpoints; %s proves absence itself during a relaunch (docs/agent-control.md)\n' "$BACKEND"
    return 0
  fi
  fm_backend_source tmux || die "the tmux adapter could not be loaded"
  identity=$(fm_endpoint_identity_state "$META")
  raw=$(fm_backend_agent_state tmux "$TARGET")
  printf 'endpoint-state: %s\n' "$raw"
  printf 'identity: %s\n' "$identity"
  if [ "$raw" != missing ]; then
    printf 'verdict: not-needed\n'
    printf 'reason: the endpoint reads %s on the tmux server this seat addresses, so no absence proof applies\n' "$raw"
    return 0
  fi
  absence=$(fm_control_endpoint_absence_verdict tmux "$TARGET" "$META" "")
  verdict=${absence%%$'\t'*}
  detail=${absence#*$'\t'}
  printf 'verdict: %s\n' "$verdict"
  if [ "$verdict" = gone ]; then
    printf 'basis: %s\n' "$detail"
  else
    printf 'reason: %s\n' "$detail"
  fi
  if [ "$identity" = legacy ]; then
    evidence=$(fm_endpoint_legacy_evidence "$META") || rc=$?
    printf 'evidence:\n'
    printf '%s\n' "$evidence" | sed 's/^/  /'
    if [ "$rc" -ne 0 ]; then
      printf 'consent: not possible while the evidence names a live endpoint or agent\n'
    else
      digest=$(printf '%s\n' "$evidence" | fm_endpoint_legacy_digest) || die "no sha256 tool is available to digest the evidence"
      printf 'consent-digest: %s\n' "$digest"
      printf 'consent: only on the captain'"'"'s explicit word for task %s, relaunch with --legacy-endpoint-consent %s\n' "$id" "$digest"
      # A live tmux server this report could not match to a scanned socket (one
      # started with its own TMUX_TMPDIR, say) may still hold the task's window,
      # and the digest cannot speak for it.
      unmapped=$(printf '%s\n' "$evidence" | sed -n 's/^info\.unmapped_tmux_servers=//p')
      case "$unmapped" in
        0) ;;
        unknown) printf 'warning: this host cannot list tmux server processes by name, so a server outside the scanned socket directories cannot be ruled out\n' ;;
        *) printf 'warning: %s live tmux server process(es) of this user could not be matched to a scanned socket; confirm none of them hosts task %s before relying on this evidence\n' "$unmapped" "$id" ;;
      esac
    fi
  fi
}

do_consents() {
  local id=$1 file line block='' digest='' ev='' got
  resolve_task "$id" || exit 1
  file="$STATE/$id.endpoint-consent"
  if [ ! -f "$file" ]; then
    printf 'no consent recorded for task %s\n' "$id"
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      consent=*) block=$line; digest=''; ev='' ;;
      digest=*) digest=${line#digest=} ;;
      ev.*) ev="$ev${line#ev.}"$'\n' ;;
      end=consent)
        got=$(printf '%s' "$ev" | fm_endpoint_legacy_digest 2>/dev/null) || got=unavailable
        printf '%s digest=%s evidence-matches-digest=%s\n' "$block" "$digest" "$([ "$got" = "$digest" ] && echo yes || echo no)"
        ;;
    esac
  done <"$file"
}

# backfill_one <id>: 0 recorded or already complete or not applicable; the
# outcome line names which.
backfill_one() {
  local id=$1 lock identity raw lines tmp label
  resolve_task "$id" || return 1
  if [ "$BACKEND" != tmux ]; then
    printf 'backfill: %s skipped (backend %s)\n' "$id" "$BACKEND"
    return 0
  fi
  identity=$(fm_endpoint_identity_state "$META")
  if [ "$identity" != legacy ]; then
    printf 'backfill: %s skipped (identity %s)\n' "$id" "$identity"
    return 0
  fi
  fm_backend_source tmux || die "the tmux adapter could not be loaded"
  raw=$(fm_backend_agent_state tmux "$TARGET")
  case "$raw" in
    alive|dead|ambiguous) ;;
    *)
      printf 'backfill: %s skipped (endpoint reads %s)\n' "$id" "$raw"
      return 0
      ;;
  esac
  label=$TARGET
  lines=$(fm_endpoint_tmux_identity_lines "=${label%%:*}:=${label#*:}" "$label") || {
    printf 'backfill: %s skipped (the endpoint identity could not be read)\n' "$id"
    return 0
  }
  lock=$(fm_meta_lock_path "$META") || die "task $id has no meta lock path"
  fm_lock_acquire_wait_bounded "$lock" 10 || die "task $id's record is locked by another action; try again"
  # Re-read under the lock: a concurrent relaunch may have just given it identity.
  if [ "$(fm_endpoint_identity_state "$META")" != legacy ]; then
    fm_lock_release "$lock" || true
    printf 'backfill: %s skipped (identity changed under the lock)\n' "$id"
    return 0
  fi
  tmp="$STATE/.$id.meta.backfill.$$"
  if ! { cat "$META"; printf '%s\n' "$lines"; } >"$tmp" || ! mv -f "$tmp" "$META"; then
    rm -f "$tmp"
    fm_lock_release "$lock" || true
    die "task $id's record could not be updated"
  fi
  fm_lock_release "$lock" || true
  printf 'backfill: %s recorded endpoint identity\n' "$id"
}

do_backfill() {
  local target=${1:-} meta id
  [ -n "$target" ] || die "backfill needs a task id or --all"
  fm_refuse_if_gate_agent
  if [ "$target" = --all ]; then
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      backfill_one "$id" || true
    done
    return 0
  fi
  backfill_one "$target"
}

case "$VERB" in
  show)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    do_show "$1"
    ;;
  consents)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    do_consents "$1"
    ;;
  backfill)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    do_backfill "$1"
    ;;
esac
