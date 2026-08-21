# shellcheck shell=bash
# fm-linear-lib.sh - shared gates, private-transport layout, and identity helpers
# for firstmate's durable Linear synchronization.
#
# The captain's rule this serves: work is not complete until the corresponding
# Linear issue is current. That rule is enforced mechanically, not by memory - a
# task is explicitly BOUND to one or more Linear issues, every handback is a
# typed durable OUTBOX record, delivery writes a RECEIPT, and cleanup refuses
# while a bound task still owes one.
#
# Sourced, never executed. No side effects on source (it creates nothing), which
# is what keeps a home with no Linear bindings free of Linear artifacts.
# set -u / set -e safe.
#
# GATE ORDER - the acceptance criterion for homes that never use Linear:
#   1. fm_linear_present <state>     one [ -d ] test on <state>/linear, the
#                                    directory only `fm-linear-sync.sh bind`
#                                    ever creates. A home with no binding stops
#                                    here: no git call, no config read, no
#                                    directory scan, and no artifact.
#   2. fm_linear_home_scoped         bin/fm-primary-scope-lib.sh's genuine
#      <home> <state>                primary-home predicate, so the whole feature
#                                    is inert inside an ordinary project repo and
#                                    inside a crewmate/scout task worktree, and
#                                    stays active in a main home or a marked
#                                    secondmate home.
#   3. credentials                   fm_linear_config_load, only on a path that
#                                    actually needs to reach Linear. Binding,
#                                    queueing, listing, and the cleanup gate all
#                                    work with no credential at all, which is what
#                                    lets a disconnected home preserve a pending
#                                    handback instead of losing it.
#
# Private transport layout, all under <state>/linear (mode 0700, created only by
# `fm-linear-sync.sh bind`):
#   bindings/<task-id>          the durable task -> issue binding. Nothing may be
#                               delivered for a task with no binding, and an
#                               ambiguous binding refuses rather than guessing.
#   outbox/<delivery-id>.json   typed pending deliveries, one file per delivery.
#                               Immutable once written: the record IS the
#                               identity, so re-queueing the same handback
#                               resolves to the same path and changes nothing.
#   sent/<delivery-id>          the receipt ledger. Presence means this exact
#                               handback is confirmed on the issue.
#   attempts/<delivery-id>      mutable retry state for a delivery that is held,
#                               kept beside the record rather than inside it so
#                               the identity never moves.
#   refused/<delivery-id>.json  a delivery Linear refused, preserved with a
#   refused/<delivery-id>.reason one-line reason. Still blocks cleanup: a refusal
#                               is an unfinished handback, not a discarded one.
#   discarded/<delivery-id>     explicit captain-authorized discards, recorded so
#                               a dropped handback stays inspectable.
#   .lock.<delivery-id>         a delivery in progress. Serializes the read-then-
#                               post sequence, which is the one duplicate the
#                               read-back cannot prevent on its own; taken over
#                               after FM_LINEAR_LOCK_STALE_SECS so a crashed
#                               delivery stays retryable rather than stranded.
#
# Delivery identity is DERIVED, never random: fm_linear_delivery_id hashes the
# exact handback content (task, issue, comment bytes, status). Re-queueing the
# identical handback after a crash, a retry, or a restart therefore lands on the
# same path, and delivery converges without a second comment.
#
# The lost-ack interval is NOT covered by the local receipt. A comment can be
# committed by Linear and the response lost before this side records anything.
# Every delivery therefore embeds fm_linear_marker <delivery-id> in the comment
# body and reads the issue's existing comments back BEFORE posting: an existing
# marker means already delivered. bin/fm-linear-sync.sh owns that sequence.
#
# Depends on bin/fm-x-lib.sh for .env-style reading and the private-artifact
# publication primitives (atomic, single-link, mode-validated), and on
# bin/fm-primary-scope-lib.sh for the primary-home predicate. Those remain those
# files' contracts and are not restated here.

_FM_LINEAR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_LINEAR_LIB_DIR="."
# shellcheck source=bin/fm-x-lib.sh
. "$_FM_LINEAR_LIB_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$_FM_LINEAR_LIB_DIR/fm-primary-scope-lib.sh"

FM_LINEAR_DIRNAME='linear'
# Consumed by the sourcing scripts, not by this library.
# shellcheck disable=SC2034
FM_LINEAR_DELIVERY_SCHEMA='fm-linear-delivery-v1'
# The read-back marker prefix. Public-safe by construction: it carries a content
# hash and nothing else, never a token, a path, or a task note.
FM_LINEAR_MARKER_PREFIX='fm-linear-sync:'
FM_LINEAR_DEFAULT_API_URL='https://api.linear.app/graphql'
# Bounded so one handback cannot become an unbounded upload, and so a single
# outbox record stays cheap to read and validate.
FM_LINEAR_COMMENT_MAX=${FM_LINEAR_COMMENT_MAX:-6000}
# How many comment pages the read-back walks before it gives up. Truncated
# read-back never posts: an unproven absence is treated as unknown, not as new.
FM_LINEAR_COMMENT_PAGE_MAX=${FM_LINEAR_COMMENT_PAGE_MAX:-10}
FM_LINEAR_COMMENT_PAGE_SIZE=${FM_LINEAR_COMMENT_PAGE_SIZE:-100}
# Seconds before a held delivery is retried. Advisory: `deliver` always retries
# when asked explicitly, this only paces an unattended sweep.
FM_LINEAR_RETRY_BACKOFF_SECS=${FM_LINEAR_RETRY_BACKOFF_SECS:-900}
# How long a per-delivery lock may sit before a later run treats it as abandoned
# and takes it over. A crashed delivery is exactly the case that must stay
# retryable, so this bound matters more than the lock it releases.
FM_LINEAR_LOCK_STALE_SECS=${FM_LINEAR_LOCK_STALE_SECS:-300}

# Resolved by fm_linear_config_load. Never printed, never passed in argv.
FM_LINEAR_API_KEY=
FM_LINEAR_API_URL=
FM_LINEAR_CONFIG_ERROR=

# --- gate 1: O(1) presence, the zero-overhead path --------------------------

fm_linear_root()          { printf '%s\n' "$1/$FM_LINEAR_DIRNAME"; }
fm_linear_bindings_dir()  { printf '%s\n' "$1/$FM_LINEAR_DIRNAME/bindings"; }
fm_linear_outbox_dir()    { printf '%s\n' "$1/$FM_LINEAR_DIRNAME/outbox"; }
fm_linear_sent_dir()      { printf '%s\n' "$1/$FM_LINEAR_DIRNAME/sent"; }
fm_linear_attempts_dir()  { printf '%s\n' "$1/$FM_LINEAR_DIRNAME/attempts"; }
fm_linear_refused_dir()   { printf '%s\n' "$1/$FM_LINEAR_DIRNAME/refused"; }
fm_linear_discarded_dir() { printf '%s\n' "$1/$FM_LINEAR_DIRNAME/discarded"; }

# fm_linear_present <state>: 0 when this home has ever bound a Linear issue.
# One [ -d ] test. Every caller outside bin/fm-linear-sync.sh starts here.
fm_linear_present() {
  local root
  root=$(fm_linear_root "$1")
  [ -d "$root" ] && [ ! -L "$root" ]
}

# fm_linear_dir_has_entry <dir>: 0 when <dir> is a real directory holding at
# least one non-dot entry. Stops at the first hit, so cost does not grow with
# the directory's size.
fm_linear_dir_has_entry() {
  local dir=$1 entry
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  for entry in "$dir"/*; do
    [ -e "$entry" ] || continue
    return 0
  done
  return 1
}

# fm_linear_has_pending <state>: 0 when this home still owes at least one Linear
# handback. A refused delivery counts: a refusal is unfinished work that needs a
# decision, never a silent discard.
fm_linear_has_pending() {
  fm_linear_dir_has_entry "$(fm_linear_outbox_dir "$1")" \
    || fm_linear_dir_has_entry "$(fm_linear_refused_dir "$1")"
}

# --- gate 2: genuine primary home -------------------------------------------

# fm_linear_home_scoped <home> <state>: the shared primary-home predicate. A
# linked task worktree and a plain project clone both fail it, so every Linear
# entrypoint is a silent no-op there even when invoked by absolute path.
fm_linear_home_scoped() {
  fm_primary_scope_matches "$1" "$2"
}

# --- gate 3: credentials ----------------------------------------------------

fm_linear_config_file() { printf '%s\n' "$1/config/linear.env"; }

# fm_linear_config_load <home>: resolve FM_LINEAR_API_KEY and FM_LINEAR_API_URL
# from the one gitignored home-local credential owner, <home>/config/linear.env.
#
# Returns 1 and sets FM_LINEAR_CONFIG_ERROR to a one-line reason when the file
# is missing or fails validation; that reason names the requirement, never the
# value. It prints NOTHING, so callers read the resolved key from the global
# rather than from a command substitution that would discard it. The key itself
# is never printed by this library and never reaches a command line: the real
# transport writes it to a 0600 header file and hands curl the file.
#
# FM_LINEAR_API_KEY_OVERRIDE wins when set, matching how every other firstmate
# client lets a direct invocation override the file.
fm_linear_config_load() {
  local home=$1 file key url mode
  FM_LINEAR_API_KEY=
  FM_LINEAR_API_URL=
  FM_LINEAR_CONFIG_ERROR=
  file=$(fm_linear_config_file "$home")
  if [ -n "${FM_LINEAR_API_KEY_OVERRIDE-}" ]; then
    key=$FM_LINEAR_API_KEY_OVERRIDE
    url=${FM_LINEAR_API_URL_OVERRIDE-}
  else
    if [ -L "$file" ] || [ ! -f "$file" ]; then
      FM_LINEAR_CONFIG_ERROR="no Linear credential at $file"
      return 1
    fi
    if ! fmx_single_link_file_valid "$file"; then
      FM_LINEAR_CONFIG_ERROR="Linear credential $file must be a plain single-link file"
      return 1
    fi
    mode=$(fm_linear_file_mode "$file") || mode=
    if [ "$mode" != 600 ]; then
      FM_LINEAR_CONFIG_ERROR="Linear credential $file must be mode 0600 (found ${mode:-unknown})"
      return 1
    fi
    key=$(fmx_env_get LINEAR_API_KEY "$file")
    url=$(fmx_env_get LINEAR_API_URL "$file")
  fi
  if [ -z "$key" ]; then
    FM_LINEAR_CONFIG_ERROR="LINEAR_API_KEY is empty in $file"
    return 1
  fi
  if ! fm_linear_secret_shape_valid "$key"; then
    FM_LINEAR_CONFIG_ERROR="LINEAR_API_KEY in $file is not a single-line credential"
    return 1
  fi
  [ -n "$url" ] || url=$FM_LINEAR_DEFAULT_API_URL
  if ! fm_linear_api_url_valid "$url"; then
    # Consumed by the sourcing scripts, not by this library.
    # shellcheck disable=SC2034
    FM_LINEAR_CONFIG_ERROR='LINEAR_API_URL must be an https:// endpoint'
    return 1
  fi
  # Consumed by the sourcing scripts, not by this library.
  # shellcheck disable=SC2034
  FM_LINEAR_API_KEY=$key
  # shellcheck disable=SC2034
  FM_LINEAR_API_URL=$url
}

# A credential must be one line of printable non-space bytes. That rejects a
# pasted multi-line block, a stray CR, and anything that could smuggle a second
# header into the request.
fm_linear_secret_shape_valid() {
  local v=$1
  [ -n "$v" ] || return 1
  [ "${#v}" -le 512 ] || return 1
  case "$v" in
    *[[:space:]]*|*[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

fm_linear_api_url_valid() {
  local v=$1
  case "$v" in
    https://*) ;;
    *) return 1 ;;
  esac
  case "$v" in
    *[[:space:]]*|*[[:cntrl:]]*) return 1 ;;
  esac
  [ "${#v}" -le 512 ]
}

fm_linear_file_mode() {
  local file=$1
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$file" 2>/dev/null
  else
    stat -c %a "$file" 2>/dev/null
  fi
}

# --- identifiers ------------------------------------------------------------

# Task ids and delivery ids compose filenames, so both are checked against a
# conservative slug before any path is built from them.
fm_linear_slug_valid() {
  local v=$1
  case "$v" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#v}" -le 128 ]
}

# fm_linear_issue_ref_valid <ref>: a Linear issue reference is either the human
# identifier a captain actually types (TEAM-123) or the API UUID. Anything else
# refuses, so a prose fragment can never be mistaken for a target.
fm_linear_issue_ref_valid() {
  local v=$1
  [ "${#v}" -le 64 ] || return 1
  if [[ "$v" =~ ^[A-Z][A-Z0-9]{0,9}-[0-9]{1,7}$ ]]; then
    return 0
  fi
  if [[ "$v" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    return 0
  fi
  return 1
}

# fm_linear_status_valid <name>: a Linear workflow state NAME as it appears in
# the team's workflow ("In Progress", "Done"). Single line, bounded, printable.
fm_linear_status_valid() {
  local v=$1
  [ -n "$v" ] || return 1
  [ "${#v}" -le 64 ] || return 1
  case "$v" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

fm_linear_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# fm_linear_delivery_id <task-id> <issue-ref> <status> <comment-file>
# The stable idempotency identity: the exact handback content and nothing else.
# The comment bytes are hashed from the file rather than passed as an argument,
# so a long handback never rides an argument list.
fm_linear_delivery_id() {
  local task=$1 issue=$2 status=$3 comment_file=$4
  {
    printf '%s\037%s\037%s\037%s\037' \
      "$FM_LINEAR_DELIVERY_SCHEMA" "$task" "$issue" "$status"
    cat -- "$comment_file"
  } | fm_linear_sha256
}

# fm_linear_marker <delivery-id>: the authoritative read-back key embedded in
# the posted comment. Linear's own copy of this string is what proves delivery
# across the lost-ack interval; the local receipt alone never does.
fm_linear_marker() {
  printf '%s%s' "$FM_LINEAR_MARKER_PREFIX" "$1"
}

# fm_linear_comment_body_suffix <delivery-id>: the exact bytes appended to the
# captain-authored comment. An HTML comment so it renders as nothing in Linear
# while staying a plain substring of the stored body.
fm_linear_comment_body_suffix() {
  printf '\n\n<!-- %s -->' "$(fm_linear_marker "$1")"
}

# --- record readers ---------------------------------------------------------

# fm_linear_binding_issues <state> <task-id>: every issue bound to <task-id>,
# one per line. Prints nothing and succeeds when the task has no binding.
fm_linear_binding_issues() {
  local state=$1 task=$2 file line
  fm_linear_slug_valid "$task" || return 1
  file="$(fm_linear_bindings_dir "$state")/$task"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      issue=*) ;;
      *) continue ;;
    esac
    line=${line#issue=}
    fm_linear_issue_ref_valid "$line" || continue
    printf '%s\n' "$line"
  done < "$file"
}

# fm_linear_bound_tasks <state>: every task id with a binding, one per line.
fm_linear_bound_tasks() {
  local dir entry
  dir=$(fm_linear_bindings_dir "$1")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  for entry in "$dir"/*; do
    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    basename "$entry"
  done
}

# fm_linear_record_field <file> <key>: read one TOP-LEVEL string or null field
# from a typed delivery record with no jq dependency, so the cleanup gate keeps
# working on a home where jq is missing.
#
# The match is anchored to the start of a line because a delivery record embeds
# the captain's comment as a JSON string: every character of it, newlines
# included, is escaped onto the single `"comment":` line. A comment that itself
# contains `"status": "Done"` therefore cannot be mistaken for the record's own
# status field. The reader is deliberately narrow and only understands the exact
# shape bin/fm-linear-sync.sh writes.
fm_linear_record_field() {
  local file=$1 key=$2 line
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  line=$(grep -m1 -E "^[[:space:]]*\"$key\":" "$file" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  line=${line#*\""$key"\":}
  line=${line#"${line%%[![:space:]]*}"}
  case "$line" in
    null*) printf '' ; return 0 ;;
    \"*) ;;
    *) return 1 ;;
  esac
  line=${line#\"}
  line=${line%%\"*}
  printf '%s' "$line"
}

# fm_linear_pending_deliveries <state> [task-id]: pending delivery ids, one per
# line, optionally filtered to one task. Outbox first, then refused, so the
# actionable set reads before the stuck set.
fm_linear_pending_deliveries() {
  local state=$1 task=${2-} dir entry id
  for dir in "$(fm_linear_outbox_dir "$state")" "$(fm_linear_refused_dir "$state")"; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    for entry in "$dir"/*.json; do
      [ -f "$entry" ] && [ ! -L "$entry" ] || continue
      id=$(basename "$entry" .json)
      if [ -n "$task" ]; then
        [ "$(fm_linear_record_field "$entry" task_id)" = "$task" ] || continue
      fi
      printf '%s\n' "$id"
    done
  done
}

# --- bounded single-line text ----------------------------------------------

# fm_linear_clean_line: read stdin, drop control characters, collapse every
# whitespace run to one space, trim. Used only for lines that are PRINTED (a
# refusal reason, a pending summary), never for the comment body itself, which
# must reach Linear byte-exact as the captain wrote it.
fm_linear_clean_line() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' \
    | LC_ALL=C tr '\011\012\015' '   ' \
    | LC_ALL=C tr -s ' ' \
    | sed 's/^ //; s/ $//'
}

fm_linear_bound_bytes() {
  LC_ALL=C cut -b "1-$1"
}
