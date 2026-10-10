#!/usr/bin/env bash
# Trusted fresh-session startup-pull coordination.
#
# This command is copied as part of a verified frozen bundle by the dotfiles
# installer.  Its own SCRIPT_DIR always names that trusted bundle, while
# --home names the independent primary checkout whose state and source may be
# inspected or advanced.  It never fetches and never executes candidate code.
#
# Usage:
#   fm-prelaunch.sh capabilities --home PHYSICAL_HOME
#   fm-prelaunch.sh profile --home PHYSICAL_HOME --harness NAME -- ARGUMENTS...
#   fm-prelaunch.sh reserve --home PHYSICAL_HOME --owner-pid PID --token TOKEN
#   fm-prelaunch.sh validate --home PHYSICAL_HOME --owner-pid PID --token TOKEN
#   fm-prelaunch.sh attach --home PHYSICAL_HOME --owner-pid PID --token TOKEN --child-pid PID
#   fm-prelaunch.sh check-update --home PHYSICAL_HOME --owner-pid PID --token TOKEN --commit SHA
#   fm-prelaunch.sh update --home PHYSICAL_HOME --owner-pid PID --token TOKEN --commit SHA
#   fm-prelaunch.sh release --home PHYSICAL_HOME --owner-pid PID --token TOKEN
#   fm-prelaunch.sh guard-write --home PHYSICAL_HOME [--owner-pid PID --token TOKEN]
#
# Every success is one JSON object on stdout.  Diagnostics contain no token,
# process identity, or credential material and go to stderr.  Any nonzero exit
# is a hard refusal for the launcher or guarded writer.
set -u

# A caller's repository-local Git environment must not redirect any inspection
# or update away from --home or its real index/object store.  This command owns
# a pinned local commit and supplies its own narrowly disabled hook/attribute
# configuration at the update boundary.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_ATTR_SOURCE
unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUNDLE_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)"

die() {
  printf 'fm-prelaunch: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-prelaunch.sh" | sed 's/^# \{0,1\}//; $d' >&2
  exit 2
}

ACTION=${1:-}
[ -n "$ACTION" ] || usage
shift

HOME_ARG=
OWNER_PID=
TOKEN=
COMMIT=
HARNESS=
CHILD_PID=
HOME_SEEN=0
OWNER_SEEN=0
TOKEN_SEEN=0
COMMIT_SEEN=0
HARNESS_SEEN=0
CHILD_SEEN=0
PROFILE_ARGS=()
PROFILE_DELIMITER=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] && [ "$HOME_SEEN" -eq 0 ] || usage
      HOME_ARG=$2
      HOME_SEEN=1
      shift 2
      ;;
    --owner-pid)
      [ "$#" -ge 2 ] && [ "$OWNER_SEEN" -eq 0 ] || usage
      OWNER_PID=$2
      OWNER_SEEN=1
      shift 2
      ;;
    --token)
      [ "$#" -ge 2 ] && [ "$TOKEN_SEEN" -eq 0 ] || usage
      TOKEN=$2
      TOKEN_SEEN=1
      shift 2
      ;;
    --commit)
      [ "$#" -ge 2 ] && [ "$COMMIT_SEEN" -eq 0 ] || usage
      COMMIT=$2
      COMMIT_SEEN=1
      shift 2
      ;;
    --harness)
      [ "$#" -ge 2 ] && [ "$HARNESS_SEEN" -eq 0 ] || usage
      HARNESS=$2
      HARNESS_SEEN=1
      shift 2
      ;;
    --child-pid)
      [ "$#" -ge 2 ] && [ "$CHILD_SEEN" -eq 0 ] || usage
      CHILD_PID=$2
      CHILD_SEEN=1
      shift 2
      ;;
    --)
      [ "$ACTION" = profile ] || usage
      shift
      PROFILE_DELIMITER=1
      PROFILE_ARGS=("$@")
      break
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ "$HOME_SEEN" -eq 1 ] || usage

case "$ACTION" in
  capabilities)
    [ "$OWNER_SEEN$TOKEN_SEEN$COMMIT_SEEN$HARNESS_SEEN$CHILD_SEEN" = 00000 ] || usage
    ;;
  profile)
    [ "$OWNER_SEEN$TOKEN_SEEN$COMMIT_SEEN$HARNESS_SEEN$CHILD_SEEN" = 00010 ] || usage
    [ "$PROFILE_DELIMITER" -eq 1 ] || usage
    ;;
  reserve|validate|release)
    [ "$OWNER_SEEN$TOKEN_SEEN$COMMIT_SEEN$HARNESS_SEEN$CHILD_SEEN" = 11000 ] || usage
    ;;
  attach)
    [ "$OWNER_SEEN$TOKEN_SEEN$COMMIT_SEEN$HARNESS_SEEN$CHILD_SEEN" = 11001 ] || usage
    ;;
  check-update|update)
    [ "$OWNER_SEEN$TOKEN_SEEN$COMMIT_SEEN$HARNESS_SEEN$CHILD_SEEN" = 11100 ] || usage
    ;;
  guard-write)
    [ "$COMMIT_SEEN$HARNESS_SEEN$CHILD_SEEN" = 000 ] || usage
    [ "$OWNER_SEEN" -eq "$TOKEN_SEEN" ] || usage
    ;;
  *) usage ;;
esac

# Load the shared identity parser before setting target-home variables.  It has
# no source-time state mutation and resolves its own dependencies relative to
# this frozen bundle.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

HOME_PHYSICAL=$(fm_prelaunch_physical_home "$HOME_ARG") \
  || die "--home must be an existing absolute physical directory"
STATE="$HOME_PHYSICAL/state"
FM_ROOT="$HOME_PHYSICAL"
FM_HOME="$HOME_PHYSICAL"
FM_ROOT_OVERRIDE="$HOME_PHYSICAL"
FM_STATE_OVERRIDE="$STATE"
export FM_ROOT FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE STATE

prelaunch_scope_check() {
  local path resolved common
  [ -f "$HOME_PHYSICAL/AGENTS.md" ] && [ ! -L "$HOME_PHYSICAL/AGENTS.md" ] \
    || die "home is not a safe Firstmate checkout"
  [ -d "$HOME_PHYSICAL/bin" ] && [ ! -L "$HOME_PHYSICAL/bin" ] \
    || die "home is not a safe Firstmate checkout"
  if [ -e "$HOME_PHYSICAL/.fm-secondmate-home" ] || [ -L "$HOME_PHYSICAL/.fm-secondmate-home" ]; then
    die "secondmate homes cannot enroll in startup pull"
  fi
  if [ -e "$HOME_PHYSICAL/.fm-lab-home" ] || [ -L "$HOME_PHYSICAL/.fm-lab-home" ]; then
    die "lab homes cannot enroll in startup pull"
  fi
  fm_prelaunch_source_identity "$HOME_PHYSICAL" >/dev/null \
    || die "home must be a standalone primary checkout, not a linked worktree"
  common=$(git -C "$HOME_PHYSICAL" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "cannot resolve source identity"
  common=$(CDPATH='' cd -- "$common" 2>/dev/null && pwd -P) \
    || die "cannot resolve source identity"
  case "$common" in */.no-mistakes/repos/*.git) die "no-mistakes worktrees cannot enroll in startup pull" ;; esac
  [ "${NO_MISTAKES_GATE+x}" != x ] || die "no-mistakes phases cannot enroll in startup pull"
  for path in data state config projects; do
    if [ -e "$HOME_PHYSICAL/$path" ] || [ -L "$HOME_PHYSICAL/$path" ]; then
      [ -d "$HOME_PHYSICAL/$path" ] && [ ! -L "$HOME_PHYSICAL/$path" ] \
        || die "$path must be a real directory inside the home"
      resolved=$(CDPATH='' cd -- "$HOME_PHYSICAL/$path" 2>/dev/null && pwd -P) \
        || die "cannot resolve $path directory"
      case "$resolved" in "$HOME_PHYSICAL"/*) ;; *) die "$path resolves outside the home" ;; esac
    fi
  done
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | tr '\n\r\t' '   '
}

json_text_safe() {
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
}

json_base() {  # <status>
  printf '{"version":1,"home":"%s","status":"%s"' \
    "$(json_escape "$HOME_PHYSICAL")" "$(json_escape "$1")"
}

# An explicit writer needs only proof that no reservation exists.  Reservation
# creation itself requires the enrollment scope below, so a home without a
# record keeps its existing write authority even when it cannot enroll.
if [ "$ACTION" = guard-write ] && [ ! -e "$STATE/$FM_PRELAUNCH_RESERVATION_FILE" ] \
  && [ ! -L "$STATE/$FM_PRELAUNCH_RESERVATION_FILE" ]; then
  json_base clear
  printf '}\n'
  exit 0
fi

prelaunch_scope_check

file_link_count() {  # <file>
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    /usr/bin/stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

BUNDLE_FILES='bin/fm-prelaunch.sh
bin/fm-session-lock-lib.sh
bin/fm-cursor-lib.sh
bin/fm-wake-lib.sh
bin/fm-path-lib.sh
bin/fm-supervision-lib.sh
bin/fm-ff-lib.sh
bin/fm-secondmate-registry-lib.sh
bin/fm-timeout-lib.sh'

bundle_files_json() {
  local rel path links out='' sep=''
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    path="$BUNDLE_ROOT/$rel"
    [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] \
      || die "trusted bundle dependency is unavailable: $rel"
    links=$(file_link_count "$path") || die "cannot inspect trusted bundle dependency: $rel"
    [ "$links" = 1 ] || die "trusted bundle dependency is multiply linked: $rel"
    out="$out$sep\"$(json_escape "$rel")\""
    sep=,
  done <<EOF
$BUNDLE_FILES
EOF
  printf '[%s]' "$out"
}

profile_add() {  # <name> <stable-binary> <version-marker> [launch-env-json]
  local name=$1 stable=$2 marker=$3 launch_env=${4:-'{}'} real version entry
  [ -n "$stable" ] && [ -x "$stable" ] || return 0
  case "$stable" in /*) ;; *) return 0 ;; esac
  real=$(fm_cursor_canonical_path "$stable" 2>/dev/null) || return 0
  [ -x "$real" ] || return 0
  json_text_safe "$real" || return 0
  version=$(fm_run_timed 5 "$stable" --version 2>/dev/null) || return 0
  version=${version%%$'\n'*}
  [ -n "$version" ] || return 0
  json_text_safe "$version" || return 0
  case "$version" in *"$marker"*) ;; *) return 0 ;; esac
  entry=$(printf '"%s":{"binary":"%s","harness_version":"%s","argv_grammar":{"kind":"exact","args":[],"session":"fresh-only"},"launch_env":%s}' \
    "$(json_escape "$name")" "$(json_escape "$real")" "$(json_escape "$version")" "$launch_env")
  PROFILES_JSON="$PROFILES_JSON${PROFILES_JSON:+,}$entry"
  if [ -n "${PROFILE_REQUEST:-}" ] && [ "$PROFILE_REQUEST" = "$name" ]; then
    PROFILE_BINARY=$real
    PROFILE_VERSION=$version
    PROFILE_LAUNCH_ENV=$launch_env
  fi
}

build_profiles() {
  local path stable
  PROFILES_JSON=
  PROFILE_BINARY=
  PROFILE_VERSION=
  PROFILE_LAUNCH_ENV=
  PROFILE_REQUEST=${PROFILE_REQUEST:-}
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  path=$(command -v claude 2>/dev/null || true)
  case "${path##*/}" in claude) profile_add claude "$path" 'Claude Code' '{}' ;; esac
  path=$(command -v codex 2>/dev/null || true)
  case "${path##*/}" in codex) profile_add codex "$path" 'codex-cli' '{}' ;; esac
  path=$(fm_cursor_resolve_binary 2>/dev/null || true)
  [ -z "$path" ] || profile_add cursor "$path" '' '{}'
  for path in opencode grok kimi pi pi-signed omp; do
    stable=$(command -v "$path" 2>/dev/null || true)
    [ "${stable##*/}" = "$path" ] || continue
    case "$path" in
      pi-signed) profile_add "$path" "$stable" '' '{"FM_PI_HARNESS":"pi-signed"}' ;;
      omp) profile_add "$path" "$stable" '' '{"FM_OMP_HARNESS":"omp"}' ;;
      *) profile_add "$path" "$stable" '' '{}' ;;
    esac
  done
}

capabilities() {
  local default source_url source_ref
  # shellcheck source=bin/fm-ff-lib.sh
  . "$SCRIPT_DIR/fm-ff-lib.sh"
  default=$(default_branch "$HOME_PHYSICAL") || die "cannot determine the default branch"
  source_url=$(git -C "$HOME_PHYSICAL" remote get-url origin 2>/dev/null) \
    || die "source has no origin remote"
  json_text_safe "$source_url" || die "source origin URL is unsafe"
  source_ref="refs/heads/$default"
  PROFILE_REQUEST=
  build_profiles
  [ -n "$PROFILES_JSON" ] || die "no supported fresh-session harness is installed"
  json_base compatible
  printf ',"bundle_files":%s,"source_remote":"origin","source_url":"%s","source_ref":"%s","profiles":{%s}}\n' \
    "$(bundle_files_json)" "$(json_escape "$source_url")" \
    "$(json_escape "$source_ref")" "$PROFILES_JSON"
}

profile() {
  case "$HARNESS" in claude|codex|cursor|opencode|grok|kimi|pi|pi-signed|omp) ;;
    *) die "unknown or unsupported harness profile" ;;
  esac
  # The v1 grammar deliberately accepts no vendor arguments.  That narrow
  # profile proves a fresh session without trying to maintain a permissive
  # denylist whose gaps could restore or fork saved state.
  [ "${#PROFILE_ARGS[@]}" -eq 0 ] || die "this fresh-session profile accepts no arguments"
  PROFILE_REQUEST=$HARNESS
  build_profiles
  [ -n "$PROFILE_BINARY" ] || die "requested harness is not installed with a verified version"
  json_base fresh
  printf ',"binary":"%s","harness_version":"%s","argv":[],"launch_env":%s}\n' \
    "$(json_escape "$PROFILE_BINARY")" "$(json_escape "$PROFILE_VERSION")" "$PROFILE_LAUNCH_ENV"
}

case "$ACTION" in
  capabilities) capabilities; exit 0 ;;
  profile) profile; exit 0 ;;
esac

mkdir -p "$STATE" 2>/dev/null || die "cannot create the reservation state directory"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die "reservation state directory is unsafe"
[ "$(CDPATH='' cd -- "$STATE" 2>/dev/null && pwd -P)" = "$STATE" ] \
  || die "reservation state directory is not physically inside the home"

# The wake library owns the existing portable mutex and PID identity.  Sourcing
# it is delayed until after capabilities so that read-only discovery never
# creates the target state directory.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

CLAIM_LOCK="$STATE/.lock.acquire"
QUEUE_LOCK="$STATE/.wake-queue.lock"
CLAIM_HELD=0
QUEUE_HELD=0
cleanup() {
  [ "$QUEUE_HELD" -eq 0 ] || fm_lock_release "$QUEUE_LOCK" || true
  [ "$CLAIM_HELD" -eq 0 ] || fm_lock_release "$CLAIM_LOCK" || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

acquire_claim() {
  fm_lock_acquire_wait_max "$CLAIM_LOCK" 5 \
    || die "session claim mutex did not become available"
  CLAIM_HELD=1
}

acquire_queue() {
  fm_lock_acquire_wait_max "$QUEUE_LOCK" 5 \
    || die "wake queue mutex did not become available"
  QUEUE_HELD=1
}

session_absent_or_reclaimed() {
  fm_session_lock_inspect "$STATE"
  case "$FM_LOCK_INSPECT_STATE" in
    free) return 0 ;;
    stale)
      rm -f -- "$STATE/.lock" "$STATE/.lock-session" \
        || die "stale session lock could not be reclaimed"
      [ ! -e "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] \
        || die "stale session lock could not be reclaimed"
      ;;
    held) die "a live primary session owns this home" ;;
    *) die "session ownership is unreadable or unknown" ;;
  esac
}

fleet_idle() {
  fm_supervision_status_strict "$STATE" \
    || die "fleet inventories are unreadable or changed during inspection"
  [ "$FM_SUP_NEEDED" = false ] || die "active fleet work requires supervision"
  [ "$FM_SUP_QUEUE_PENDING" = false ] || die "the wake queue has pending work"
}

# Classify the existing dotfiles publication mutex without changing it.
# Reservation creation refuses a live owner and every ambiguous shape.  A
# positively dead owner remains the dotfiles workflow's recovery concern; this
# helper never removes another subsystem's lock.
dotfiles_mutation_lock_state() {
  local state lock pid
  state=${HOME:-}/.local/state/dotfiles
  lock="$state/lock"
  DOTFILES_LOCK_STATE=unknown
  case "$state" in /*) ;; *) return 0 ;; esac
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    DOTFILES_LOCK_STATE=free
    return 0
  fi
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 0
  [ -f "$lock/pid" ] && [ ! -L "$lock/pid" ] && [ -r "$lock/pid" ] || return 0
  pid=$(cat "$lock/pid" 2>/dev/null) || return 0
  case "$pid" in ''|*[!0-9]*|0|*$'\n'*|*$'\r'*) return 0 ;; esac
  if kill -0 "$pid" 2>/dev/null; then
    DOTFILES_LOCK_STATE=live
  elif ps -o comm= -p "$pid" >/dev/null 2>&1; then
    DOTFILES_LOCK_STATE=unknown
  else
    DOTFILES_LOCK_STATE=stale
  fi
}

require_dotfiles_writer_absent() {
  dotfiles_mutation_lock_state
  case "$DOTFILES_LOCK_STATE" in
    free|stale) return 0 ;;
    live) die "a live dotfiles publication owns the mutation lock" ;;
    *) die "dotfiles publication ownership is unreadable or unknown" ;;
  esac
}

authenticate_owner_shape() {
  case "$OWNER_PID" in ''|*[!0-9]*|0) die "owner pid must be a positive integer" ;; esac
  fm_prelaunch_token_valid "$TOKEN" || die "token format is invalid"
  fm_prelaunch_owner_is_ancestor "$OWNER_PID" \
    || die "caller is not the named launcher or its descendant"
}

authenticate_reservation() {
  authenticate_owner_shape
  fm_prelaunch_reservation_authenticated "$STATE" "$HOME_PHYSICAL" "$OWNER_PID" "$TOKEN" \
    || die "reservation ownership could not be authenticated"
}

commit_object() {
  local resolved length=${#COMMIT}
  [ "$length" -eq 40 ] || [ "$length" -eq 64 ] || die "commit must be a full object id"
  case "$COMMIT" in *[!0-9a-f]*) die "commit must be a lowercase hexadecimal object id" ;; esac
  resolved=$(git -C "$HOME_PHYSICAL" rev-parse --verify "$COMMIT^{commit}" 2>/dev/null) \
    || die "pinned commit is not available locally"
  [ "$resolved" = "$COMMIT" ] || die "pinned commit did not resolve exactly"
}

validated_idle_reservation() {
  authenticate_reservation
  session_absent_or_reclaimed
  acquire_queue
  fleet_idle
}

reserve() {
  local home_identity source_identity owner_identity owner_hash token_hash source_head created
  authenticate_owner_shape
  acquire_claim
  session_absent_or_reclaimed
  acquire_queue
  fleet_idle
  require_dotfiles_writer_absent
  fm_prelaunch_reservation_inspect "$STATE" "$HOME_PHYSICAL"
  case "$FM_PRELAUNCH_INSPECT_STATE" in
    free) ;;
    stale)
      rm -f -- "$STATE/$FM_PRELAUNCH_RESERVATION_FILE" \
        || die "stale reservation could not be reclaimed"
      ;;
    live)
      if fm_prelaunch_reservation_authenticated "$STATE" "$HOME_PHYSICAL" "$OWNER_PID" "$TOKEN"; then
        json_base reserved
        printf ',"source_head":"%s"}\n' "$FM_PRELAUNCH_RECORD_SOURCE_COMMIT"
        return 0
      fi
      die "another live startup reservation owns this home"
      ;;
    *) die "startup reservation ownership is unreadable or unknown" ;;
  esac
  if [ -e "$STATE/$FM_PRELAUNCH_HANDOFF_FILE" ] || [ -L "$STATE/$FM_PRELAUNCH_HANDOFF_FILE" ]; then
    [ -f "$STATE/$FM_PRELAUNCH_HANDOFF_FILE" ] && [ ! -L "$STATE/$FM_PRELAUNCH_HANDOFF_FILE" ] \
      || die "prior startup handoff is unsafe"
    rm -f -- "$STATE/$FM_PRELAUNCH_HANDOFF_FILE" \
      || die "prior startup handoff could not be cleared"
  fi
  home_identity=$(fm_prelaunch_directory_identity "$HOME_PHYSICAL") \
    || die "cannot bind physical home identity"
  source_identity=$(fm_prelaunch_source_identity "$HOME_PHYSICAL") \
    || die "cannot bind source identity"
  owner_identity=$(fm_pid_identity "$OWNER_PID") \
    || die "cannot bind launcher process identity"
  owner_hash=$(fm_prelaunch_hash_text "$owner_identity") \
    || die "cannot hash launcher process identity"
  token_hash=$(fm_prelaunch_hash_text "$TOKEN") || die "cannot hash invocation token"
  source_head=$(git -C "$HOME_PHYSICAL" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
    || die "cannot read source HEAD"
  created=$(date +%s) || die "cannot read the system clock"
  fm_prelaunch_reservation_write "$STATE" "$HOME_PHYSICAL" "$home_identity" \
    "$source_identity" "$OWNER_PID" "$owner_hash" "$token_hash" \
    '' '' "$source_head" '' pending "$created" \
    || die "reservation could not be published"
  fm_prelaunch_reservation_authenticated "$STATE" "$HOME_PHYSICAL" "$OWNER_PID" "$TOKEN" \
    || die "reservation publication could not be verified"
  # Close the cross-mutex check/write race with manual publication.  A manual
  # writer that acquired its lock before our record appeared was legitimately
  # admitted by guard-write; if it is still present now, withdraw only this
  # reservation and refuse before any startup mutation can begin.
  dotfiles_mutation_lock_state
  case "$DOTFILES_LOCK_STATE" in
    free|stale) ;;
    *)
      rm -f -- "$STATE/$FM_PRELAUNCH_RESERVATION_FILE" \
        || die "dotfiles publication raced reservation and rollback failed"
      die "dotfiles publication raced startup reservation"
      ;;
  esac
  json_base reserved
  printf ',"source_head":"%s"}\n' "$source_head"
}

attach() {
  local generation generation_hash
  case "$CHILD_PID" in ''|*[!0-9]*|0) die "child pid must be a positive integer" ;; esac
  [ "$CHILD_PID" != "$OWNER_PID" ] || die "attached child must differ from its launcher"
  acquire_claim
  validated_idle_reservation
  [ -z "$FM_PRELAUNCH_RECORD_CHILD_PID" ] \
    || die "a child is already attached to this reservation"
  fm_prelaunch_pid_is_descendant "$OWNER_PID" "$CHILD_PID" \
    || die "child is not a descendant of the reserved launcher"
  generation=$(fm_prelaunch_pid_generation "$CHILD_PID") \
    || die "cannot bind child process generation"
  generation_hash=$(fm_prelaunch_hash_text "$generation") \
    || die "cannot hash child process generation"
  fm_prelaunch_reservation_write "$STATE" "$FM_PRELAUNCH_RECORD_HOME" \
    "$FM_PRELAUNCH_RECORD_HOME_IDENTITY" "$FM_PRELAUNCH_RECORD_SOURCE_IDENTITY" \
    "$FM_PRELAUNCH_RECORD_OWNER_PID" "$FM_PRELAUNCH_RECORD_OWNER_IDENTITY_HASH" \
    "$FM_PRELAUNCH_RECORD_TOKEN_HASH" "$CHILD_PID" "$generation_hash" \
    "$FM_PRELAUNCH_RECORD_SOURCE_COMMIT" "$FM_PRELAUNCH_RECORD_TARGET_COMMIT" \
    "$FM_PRELAUNCH_RECORD_UPDATE_STATUS" "$FM_PRELAUNCH_RECORD_CREATED_AT" \
    || die "attached child could not be published"
  authenticate_reservation
  fm_prelaunch_attached_child_inspect
  [ "$FM_PRELAUNCH_CHILD_STATE" = live ] \
    || die "attached child publication could not be verified"
  json_base attached
  printf ',"child_pid":%s}\n' "$CHILD_PID"
}

validate() {
  local head
  acquire_claim
  validated_idle_reservation
  head=$(git -C "$HOME_PHYSICAL" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
    || die "cannot read source HEAD"
  case "$FM_PRELAUNCH_RECORD_UPDATE_STATUS" in
    pending) [ "$head" = "$FM_PRELAUNCH_RECORD_SOURCE_COMMIT" ] \
      || die "source HEAD changed after reservation" ;;
    current|updated) [ "$head" = "$FM_PRELAUNCH_RECORD_TARGET_COMMIT" ] \
      || die "source HEAD changed after startup update" ;;
  esac
  json_base valid
  printf ',"source_head":"%s"}\n' "$head"
}

preflight_or_update() {  # <check|update>
  local operation=$1 head before changed=false
  acquire_claim
  validated_idle_reservation
  commit_object
  head=$(git -C "$HOME_PHYSICAL" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
    || die "cannot read source HEAD"
  if [ "$FM_PRELAUNCH_RECORD_UPDATE_STATUS" != pending ]; then
    [ "$FM_PRELAUNCH_RECORD_TARGET_COMMIT" = "$COMMIT" ] \
      && [ "$head" = "$COMMIT" ] \
      || die "a different startup update was already recorded"
    json_base current
    printf ',"source_head":"%s","changed":false}\n' "$head"
    return 0
  fi
  [ "$head" = "$FM_PRELAUNCH_RECORD_SOURCE_COMMIT" ] \
    || die "source HEAD changed after reservation"
  before=$head
  if [ "$operation" = check ]; then
    ff_target "$HOME_PHYSICAL" 'firstmate startup' "$COMMIT" no no '' '' startup-check \
      >/dev/null 2>&1
  else
    ff_target "$HOME_PHYSICAL" 'firstmate startup' "$COMMIT" no no '' '' startup-update \
      >/dev/null 2>&1
  fi
  case "$FF_STATUS" in current|updated) ;; *) die "source update refused by the guarded fast-forward" ;; esac
  if [ "$operation" = check ]; then
    json_base "$FF_STATUS"
    [ "$FF_STATUS" != updated ] || changed=true
    printf ',"source_head":"%s","changed":%s}\n' "$COMMIT" "$changed"
    return 0
  fi
  head=$(git -C "$HOME_PHYSICAL" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
    || die "cannot verify source HEAD after update"
  [ "$head" = "$COMMIT" ] || die "source update did not reach the pinned commit"
  [ "$before" = "$head" ] || changed=true
  fm_prelaunch_reservation_write "$STATE" "$FM_PRELAUNCH_RECORD_HOME" \
    "$FM_PRELAUNCH_RECORD_HOME_IDENTITY" "$FM_PRELAUNCH_RECORD_SOURCE_IDENTITY" \
    "$FM_PRELAUNCH_RECORD_OWNER_PID" "$FM_PRELAUNCH_RECORD_OWNER_IDENTITY_HASH" \
    "$FM_PRELAUNCH_RECORD_TOKEN_HASH" "$FM_PRELAUNCH_RECORD_CHILD_PID" \
    "$FM_PRELAUNCH_RECORD_CHILD_GENERATION_HASH" "$FM_PRELAUNCH_RECORD_SOURCE_COMMIT" \
    "$COMMIT" "$FF_STATUS" "$FM_PRELAUNCH_RECORD_CREATED_AT" \
    || die "updated reservation could not be published"
  fm_prelaunch_reservation_authenticated "$STATE" "$HOME_PHYSICAL" "$OWNER_PID" "$TOKEN" \
    || die "updated reservation could not be verified"
  json_base "$FF_STATUS"
  printf ',"source_head":"%s","changed":%s}\n' "$head" "$changed"
}

release() {
  acquire_claim
  authenticate_owner_shape
  fm_prelaunch_reservation_inspect "$STATE" "$HOME_PHYSICAL"
  case "$FM_PRELAUNCH_INSPECT_STATE" in
    live)
      fm_prelaunch_reservation_authenticated "$STATE" "$HOME_PHYSICAL" "$OWNER_PID" "$TOKEN" \
        || die "reservation ownership could not be authenticated"
      fm_prelaunch_attached_child_inspect
      [ "$FM_PRELAUNCH_CHILD_STATE" != live ] \
        || die "an attached live child must exit or complete session-lock handoff before release"
      [ "$FM_PRELAUNCH_CHILD_STATE" != unknown ] \
        || die "attached child ownership is unreadable or unknown"
      rm -f -- "$STATE/$FM_PRELAUNCH_RESERVATION_FILE" \
        || die "reservation could not be released"
      json_base released
      printf '}\n'
      ;;
    free)
      fm_prelaunch_handoff_authenticated "$STATE" "$HOME_PHYSICAL" "$OWNER_PID" "$TOKEN" \
        || die "no authenticated reservation or handoff exists"
      json_base handed-off
      printf '}\n'
      ;;
    stale) die "only the verified live reservation owner may release it" ;;
    *) die "startup reservation ownership is unreadable or unknown" ;;
  esac
}

guard_write() {
  acquire_claim
  fm_prelaunch_reservation_inspect "$STATE" "$HOME_PHYSICAL"
  case "$FM_PRELAUNCH_INSPECT_STATE" in
    free)
      json_base clear
      printf '}\n'
      ;;
    stale)
      rm -f -- "$STATE/$FM_PRELAUNCH_RESERVATION_FILE" \
        || die "stale reservation could not be reclaimed"
      json_base clear
      printf '}\n'
      ;;
    live)
      [ "$OWNER_SEEN" -eq 1 ] \
        || die "a live startup reservation blocks this write"
      fm_prelaunch_reservation_authenticated "$STATE" "$HOME_PHYSICAL" "$OWNER_PID" "$TOKEN" \
        || die "live startup reservation belongs to another owner"
      json_base owned
      printf '}\n'
      ;;
    *) die "startup reservation ownership is unreadable or unknown" ;;
  esac
}

case "$ACTION" in
  reserve) reserve ;;
  validate) validate ;;
  attach) attach ;;
  check-update) preflight_or_update check ;;
  update) preflight_or_update update ;;
  release) release ;;
  guard-write) guard_write ;;
esac
