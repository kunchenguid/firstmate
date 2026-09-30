#!/usr/bin/env bash
# fm-claim.sh - record, release, and inspect cross-home work claims.
#
# A work claim is how one firstmate home tells every other home on the same
# machine "I am working this PR / issue / file area". Before a lane is dispatched
# against such a target, claim it; a claim held by another live home refuses
# rather than racing it. The record format, the machine-wide claim root, the
# canonical-target rules, and the exit codes are owned by docs/configuration.md
# under "Cross-home work claims"; bin/fm-claim-lib.sh owns the mechanism.
#
# Usage:
#   fm-claim.sh acquire <target> [--kind pr|issue|area] --task <id> [--home <path>]
#       Take the claim for <target> on behalf of <id> in <home> (default: the
#       resolved FM_HOME). Idempotent when this same home and task already hold
#       it. Replaces a claim whose holder is provably gone; otherwise refuses.
#   fm-claim.sh release <target> [--kind pr|issue|area] --task <id> [--home <path>]
#       Drop a claim this home and task hold. Releasing a claim someone else
#       holds is refused; releasing an absent claim is a success no-op.
#   fm-claim.sh release-task <task> [--home <path>]
#       Drop every claim this home's <task> holds. Safe to run when the claim
#       store is absent; never creates it. Used on cleanup.
#   fm-claim.sh reclaim <target> [--kind pr|issue|area] --task <id> [--home <path>]
#       Take over a claim only when its holder is PROVABLY gone (recorded home
#       missing, or task record absent past the pending grace). Refuses a live
#       claim. Recovery path for a crashed home's leaked claim.
#   fm-claim.sh status <target> [--kind pr|issue|area]
#       Print "<state>\t<key>\t<home>\t<task>\t<created>\t<target>" where state
#       is held or stale, or "free: <key>" when no claim exists.
#   fm-claim.sh list
#       Print every claim record in the same tab-separated shape, one per line.
#   fm-claim.sh key <target> [--kind pr|issue|area]
#       Print only the canonical key, for records and shell composition.
#
# <target> is a GitHub PR or issue URL, an `owner/repo#N` ref, a bare ticket id
# such as LIN-123 (--kind issue), or `area:<project>:<path>`.
# A bare `owner/repo#N` defaults to --kind pr because GitHub numbers issues and
# PRs in one space; pass --kind issue for an issue reference.
#
# Exit codes: 0 ok; 1 error; 2 usage; 3 refused (another live claim holds it);
# 4 reclaim refused (the claim is not provably stale); 5 unreadable claim record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-claim-lib.sh
. "$SCRIPT_DIR/fm-claim-lib.sh"

FM_CLAIM_ACTIVE_MUTEX=
# shellcheck disable=SC2329 # Invoked indirectly: the EXIT trap below calls it.
fm_claim_release_active_mutex() {
  [ -n "$FM_CLAIM_ACTIVE_MUTEX" ] || return 0
  fm_claim_mutex_release "$FM_CLAIM_ACTIVE_MUTEX"
  FM_CLAIM_ACTIVE_MUTEX=
}
trap fm_claim_release_active_mutex EXIT

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: fm-claim.sh <command> [args]
  acquire <target> [--kind pr|issue|area] --task <id> [--home <path>]
  release <target> [--kind pr|issue|area] --task <id> [--home <path>]
  release-task <task> [--home <path>]
  reclaim <target> [--kind pr|issue|area] --task <id> [--home <path>]
  status <target> [--kind pr|issue|area]
  list
  key <target> [--kind pr|issue|area]
EOF
  exit 2
}

# --- argument helpers -------------------------------------------------------

TARGET=
KIND=
TASK=
HOME=
KEY=
PATH_CLAIM=

DEFAULT_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
if [ -d "$DEFAULT_HOME" ]; then
  DEFAULT_HOME=$(cd "$DEFAULT_HOME" && pwd -P)
fi

# parse_options <need-target> <need-task> <need-home> <option>...
# Records TARGET/KIND/TASK/HOME and validates the shape the command needs.
parse_options() {
  local need_target=$1 need_task=$2 need_home=$3
  shift 3
  TARGET=
  KIND=
  TASK=
  HOME=
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --kind)
      KIND=${2:-}
      shift 2 || usage
      ;;
    --kind=*)
      KIND=${1#--kind=}
      shift
      ;;
    --task)
      TASK=${2:-}
      shift 2 || usage
      ;;
    --task=*)
      TASK=${1#--task=}
      shift
      ;;
    --home)
      HOME=${2:-}
      shift 2 || usage
      ;;
    --home=*)
      HOME=${1#--home=}
      shift
      ;;
    -h | --help)
      usage
      ;;
    --*)
      usage
      ;;
    *)
      if [ "$need_target" -eq 1 ]; then
        if [ -z "$TARGET" ]; then
          TARGET=$1
        else
          usage
        fi
      elif [ "$need_task" -eq 1 ]; then
        if [ -z "$TASK" ]; then
          TASK=$1
        else
          usage
        fi
      else
        usage
      fi
      shift
      ;;
    esac
  done

  if [ "$need_target" -eq 1 ]; then
    [ -n "$TARGET" ] || usage
    if [ -n "$KIND" ]; then
      fm_claim_kind_valid "$KIND" || die "invalid --kind '${KIND}' (expected pr, issue, or area)"
    else
      KIND=$(fm_claim_kind_of "$TARGET") ||
        die "cannot infer a claim kind for '$TARGET'; pass --kind pr, issue, or area"
    fi
    KEY=$(fm_claim_normalize "$KIND" "$TARGET") ||
      die "invalid ${KIND} target: $TARGET"
    fm_claim_key_valid "$KEY" || die "unsafe canonical claim key"
    PATH_CLAIM=$(fm_claim_path "$KEY") || die "cannot compute the claim path (need shasum or sha256sum)"
  fi

  if [ "$need_task" -eq 1 ]; then
    [ -n "$TASK" ] || usage
    fm_claim_task_valid "$TASK" ||
      die "invalid task id '${TASK:-<empty>}' (expected [A-Za-z0-9._-], max 128)"
  fi

  if [ "$need_home" -eq 1 ]; then
    if [ -z "$HOME" ]; then
      HOME=$DEFAULT_HOME
    fi
    if [ -d "$HOME" ]; then
      HOME=$(cd "$HOME" && pwd -P)
    fi
    case "$HOME" in
    /*) ;;
    *) die "home path must be absolute: $HOME" ;;
    esac
    case "$HOME" in
    *$'\n'*) die "home path must not contain a newline" ;;
    esac
  fi
}

ensure_root() {
  local root
  root=$(fm_claim_root) || die "cannot resolve the claim root"
  if [ ! -e "$root" ] && [ ! -L "$root" ]; then
    (umask 077; mkdir -p "$root") 2>/dev/null || die "cannot create the claim root $root"
  fi
  fm_claim_root_ok "$root" ||
    die "claim root $root is not a private directory (it must be a real directory, not a symlink, with mode 0700)"
}

begin_mutex() {  # <lockdir>
  fm_claim_mutex_acquire "$1" || die "the claim store is busy for $KEY; retry"
  FM_CLAIM_ACTIVE_MUTEX=$1
}

# --- commands ---------------------------------------------------------------

cmd_key() {
  printf '%s\n' "$KEY"
  return 0
}

cmd_status() {
  if [ ! -e "$PATH_CLAIM" ] && [ ! -L "$PATH_CLAIM" ]; then
    printf 'free: %s\n' "$KEY"
    return 0
  fi
  if ! fm_claim_read "$PATH_CLAIM"; then
    echo "error: the claim record at $PATH_CLAIM is unreadable or corrupt" >&2
    return 5
  fi
  local state=held
  fm_claim_stale "$PATH_CLAIM" && state=stale
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$state" "$FM_CLAIM_KEY" "$FM_CLAIM_HOME" "$FM_CLAIM_TASK" "$FM_CLAIM_CREATED" "$FM_CLAIM_TARGET"
  return 0
}

cmd_list() {
  local root path state
  root=$(fm_claim_root) || die "cannot resolve the claim root"
  [ -d "$root" ] || return 0
  for path in "$root"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    fm_claim_read "$path" || continue
    state=held
    fm_claim_stale "$path" && state=stale
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$state" "$FM_CLAIM_KEY" "$FM_CLAIM_HOME" "$FM_CLAIM_TASK" "$FM_CLAIM_CREATED" "$FM_CLAIM_TARGET"
  done
  return 0
}

cmd_acquire() {
  [ -d "$HOME" ] || die "claim home does not exist: $HOME"
  ensure_root
  local lockdir="${PATH_CLAIM}.lock.d"
  begin_mutex "$lockdir"
  if [ -e "$PATH_CLAIM" ] || [ -L "$PATH_CLAIM" ]; then
    if ! fm_claim_read "$PATH_CLAIM"; then
      echo "error: claim refused - the existing claim record at $PATH_CLAIM is unreadable or corrupt" >&2
      return 5
    fi
    if [ "$FM_CLAIM_HOME" = "$HOME" ] && [ "$FM_CLAIM_TASK" = "$TASK" ]; then
      printf 'acquired: %s is already held by home %s for task %s\n' "$KEY" "$HOME" "$TASK"
      return 0
    fi
    if fm_claim_stale "$PATH_CLAIM"; then
      local phome=$FM_CLAIM_HOME ptask=$FM_CLAIM_TASK pcreated=$FM_CLAIM_CREATED
      fm_claim_write_record "$PATH_CLAIM" "$KEY" "$KIND" "$TARGET" "$HOME" "$TASK" ||
        die "could not replace the stale claim at $PATH_CLAIM"
      printf 'reclaimed: %s was left by a stale claim (home %s task %s, since %s); now held by home %s for task %s\n' \
        "$KEY" "$phome" "$ptask" "$pcreated" "$HOME" "$TASK"
      return 0
    fi
    echo "error: claim refused - $KEY is held by home $FM_CLAIM_HOME for task $FM_CLAIM_TASK (since $FM_CLAIM_CREATED)" >&2
    return 3
  fi
  fm_claim_write_record "$PATH_CLAIM" "$KEY" "$KIND" "$TARGET" "$HOME" "$TASK" ||
    die "could not write the claim at $PATH_CLAIM"
  printf 'acquired: %s is held by home %s for task %s\n' "$KEY" "$HOME" "$TASK"
  return 0
}

cmd_release() {
  if [ ! -e "$PATH_CLAIM" ] && [ ! -L "$PATH_CLAIM" ]; then
    printf 'free: no claim for %s\n' "$KEY"
    return 0
  fi
  if ! fm_claim_read "$PATH_CLAIM"; then
    echo "error: the claim record at $PATH_CLAIM is unreadable or corrupt" >&2
    return 5
  fi
  if [ "$FM_CLAIM_HOME" != "$HOME" ] || [ "$FM_CLAIM_TASK" != "$TASK" ]; then
    echo "error: release refused - $KEY is held by home $FM_CLAIM_HOME for task $FM_CLAIM_TASK, not by home $HOME for task $TASK" >&2
    return 3
  fi
  begin_mutex "${PATH_CLAIM}.lock.d"
  rm -f -- "$PATH_CLAIM" || die "could not remove the claim at $PATH_CLAIM"
  printf 'released: %s\n' "$KEY"
  return 0
}

cmd_release_task() {
  local root path removed=0
  root=$(fm_claim_root) || die "cannot resolve the claim root"
  if [ ! -d "$root" ]; then
    printf 'released 0 claim(s) for home %s task %s\n' "$HOME" "$TASK"
    return 0
  fi
  for path in "$root"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    fm_claim_read "$path" || continue
    if [ "$FM_CLAIM_HOME" = "$HOME" ] && [ "$FM_CLAIM_TASK" = "$TASK" ]; then
      if rm -f -- "$path"; then
        removed=$((removed + 1))
      fi
    fi
  done
  printf 'released %s claim(s) for home %s task %s\n' "$removed" "$HOME" "$TASK"
  return 0
}

cmd_reclaim() {
  if [ ! -e "$PATH_CLAIM" ] && [ ! -L "$PATH_CLAIM" ]; then
    printf 'free: no claim for %s\n' "$KEY"
    return 0
  fi
  if ! fm_claim_read "$PATH_CLAIM"; then
    echo "error: the claim record at $PATH_CLAIM is unreadable or corrupt" >&2
    return 5
  fi
  if [ "$FM_CLAIM_HOME" = "$HOME" ] && [ "$FM_CLAIM_TASK" = "$TASK" ]; then
    printf 'held: %s is already held by home %s for task %s\n' "$KEY" "$HOME" "$TASK"
    return 0
  fi
  if ! fm_claim_stale "$PATH_CLAIM"; then
    echo "error: reclaim refused - $KEY is held by home $FM_CLAIM_HOME for task $FM_CLAIM_TASK and is not provably stale (its task record is present, or the claim is within the pending grace window)" >&2
    return 4
  fi
  begin_mutex "${PATH_CLAIM}.lock.d"
  # Re-check under the mutex: a concurrent acquirer may have replaced it.
  if [ -e "$PATH_CLAIM" ] || [ -L "$PATH_CLAIM" ]; then
    fm_claim_read "$PATH_CLAIM" || die "the claim at $PATH_CLAIM became unreadable while reclaiming"
    if [ "$FM_CLAIM_HOME" = "$HOME" ] && [ "$FM_CLAIM_TASK" = "$TASK" ]; then
      printf 'held: %s is already held by home %s for task %s\n' "$KEY" "$HOME" "$TASK"
      return 0
    fi
    if ! fm_claim_stale "$PATH_CLAIM"; then
      echo "error: reclaim refused - $KEY was re-claimed while reclaiming and is no longer provably stale" >&2
      return 4
    fi
  fi
  local phome=$FM_CLAIM_HOME ptask=$FM_CLAIM_TASK pcreated=$FM_CLAIM_CREATED
  fm_claim_write_record "$PATH_CLAIM" "$KEY" "$KIND" "$TARGET" "$HOME" "$TASK" ||
    die "could not write the reclaimed claim at $PATH_CLAIM"
  printf 'reclaimed: %s was left by a stale claim (home %s task %s, since %s); now held by home %s for task %s\n' \
    "$KEY" "$phome" "$ptask" "$pcreated" "$HOME" "$TASK"
  return 0
}

# --- dispatch ---------------------------------------------------------------

CMD=${1:-}
shift 2>/dev/null || true
case "$CMD" in
acquire)
  parse_options 1 1 1 "$@"
  cmd_acquire
  exit $?
  ;;
release)
  parse_options 1 1 1 "$@"
  cmd_release
  exit $?
  ;;
release-task)
  parse_options 0 1 1 "$@"
  cmd_release_task
  exit $?
  ;;
reclaim)
  parse_options 1 1 1 "$@"
  cmd_reclaim
  exit $?
  ;;
status)
  parse_options 1 0 0 "$@"
  cmd_status
  exit $?
  ;;
key)
  parse_options 1 0 0 "$@"
  cmd_key
  exit $?
  ;;
list)
  [ "$#" -eq 0 ] || usage
  cmd_list
  exit $?
  ;;
'' | -h | --help | help)
  usage
  ;;
*)
  usage
  ;;
esac
