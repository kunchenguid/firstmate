#!/usr/bin/env bash
# Declare, to any time-capture tool watching, what the CURRENT session is working on.
#
# Usage:
#   fm-declare-work.sh <work-item> [--repo <path>] [--remote <host/owner/name>] [--label <text>]
#   fm-declare-work.sh --project <path> <work-item> [--label <text>]
#   fm-declare-work.sh --clear
#   fm-declare-work.sh --help
#
# Why this exists.
#   Firstmate is a control plane. The captain types in the firstmate home and
#   the work happens somewhere else entirely - a treehouse worktree, a pipeline
#   lane, another repository. A capture tool watching the keyboard sees only the
#   firstmate home, so the captain's real, typed, human time on a client's work
#   is recorded against firstmate itself and bills as internal.
#
#   Measured over one month on the captain's machine: on the day he moved from
#   typing in the client's repository to directing work from here, his billable
#   time for that client fell to zero, while fifty hours of that client's work
#   was produced. Ten and a half hours of genuine direction filed as internal.
#
#   The environment cannot carry the fact. A directing session is long-lived and
#   serves several pieces of work in turn, while an exported variable is fixed
#   when the process starts - which is why a spawned lane can be labelled by its
#   environment and the session that spawned it cannot.
#
# What it writes.
#   One small JSON file per harness session, under the capture tool's
#   declarations directory, naming the work item and the repository that work
#   belongs to. It never names a client, an engagement, or a rate: who a
#   repository bills to is the operator's own configuration to decide, and
#   firstmate has no business asserting it.
#
# Safety contract.
#   - Writes nothing and exits 0 when no capture tool is configured, so this is
#     inert on a machine that does not use one.
#   - Writes nothing and exits 0 when the session id is unknown, rather than
#     guessing an owner for the declaration.
#   - Never fails a caller. Firstmate's own work must not stop because a
#     bookkeeping file could not be written.
#   - Refuses a session id that is not a plain filename component, rather than
#     sanitising one, because a silently rewritten path names a file nobody meant.
#
# The declaration is deliberately short-lived at the reader's end: it expires
# unless rewritten. Re-run this whenever the work in hand changes. Stale is
# expected and safe - it falls back to location-based attribution, which
# under-attributes rather than mis-attributes.

set -u

usage() {
  sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Where the capture tool reads declarations from. Resolution order matches
# worklog's own: an explicit override, then the store location, then its
# default. Absent every one of them, there is no capture tool to talk to.
declarations_dir() {
  if [ -n "${WORKLOG_DECLARATIONS_DIR:-}" ]; then
    printf '%s\n' "$WORKLOG_DECLARATIONS_DIR"
    return 0
  fi
  if [ -n "${WORKLOG_STORE_DIR:-}" ]; then
    printf '%s/declarations\n' "$WORKLOG_STORE_DIR"
    return 0
  fi
  local state="${XDG_STATE_HOME:-$HOME/.local/state}"
  if [ -d "$state/worklog" ]; then
    printf '%s/worklog/declarations\n' "$state"
    return 0
  fi
  return 1
}

# A session id that is safe to use as a filename. Refused, never repaired.
usable_session_id() {
  case "$1" in
    '' | '.' | '..') return 1 ;;
    */* | *\\*) return 1 ;;
    *) return 0 ;;
  esac
}

# Minimal JSON string escaping for the fields written below.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\000-\010\013\014\016-\037'
}

# The normalised remote of a repository, in the host/owner/name shape a capture
# tool compares against. Prints nothing when there is no usable remote.
remote_of_repo() {
  local repo=$1 url
  url=$(git -C "$repo" config --get remote.origin.url 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  printf '%s\n' "$url" |
    sed -e 's#^[a-z+]*://##' -e 's#^[^@]*@##' -e 's#:#/#' -e 's#\.git$##' -e 's#/*$##'
}

WORK_ITEM=''
REPO=''
REMOTE=''
LABEL=''
CLEAR=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --clear) CLEAR=1 ;;
    --project | --repo)
      REPO=${2:-}
      shift
      ;;
    --project=* | --repo=*) REPO=${1#*=} ;;
    --remote)
      REMOTE=${2:-}
      shift
      ;;
    --remote=*) REMOTE=${1#*=} ;;
    --label)
      LABEL=${2:-}
      shift
      ;;
    --label=*) LABEL=${1#*=} ;;
    -*)
      echo "fm-declare-work.sh: unknown option: $1" >&2
      exit 2
      ;;
    *) [ -n "$WORK_ITEM" ] || WORK_ITEM=$1 ;;
  esac
  shift
done

SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
usable_session_id "$SESSION_ID" || exit 0

DIR=$(declarations_dir) || exit 0
FILE="$DIR/$SESSION_ID.json"

if [ "$CLEAR" -eq 1 ]; then
  rm -f "$FILE" 2>/dev/null || true
  exit 0
fi

[ -n "$WORK_ITEM" ] || {
  echo "fm-declare-work.sh: a work item is required (or --clear)" >&2
  exit 2
}

if [ -n "$REPO" ] && [ -z "$REMOTE" ]; then
  REMOTE=$(remote_of_repo "$REPO" 2>/dev/null) || REMOTE=''
fi

mkdir -p "$DIR" 2>/dev/null || exit 0

NOW_MS=$(( $(date +%s) * 1000 ))

{
  printf '{"sessionId":"%s","workItem":"%s"' \
    "$(json_escape "$SESSION_ID")" "$(json_escape "$WORK_ITEM")"
  [ -n "$LABEL" ] && printf ',"label":"%s"' "$(json_escape "$LABEL")"
  [ -n "$REPO" ] && printf ',"repoRoot":"%s"' "$(json_escape "$REPO")"
  [ -n "$REMOTE" ] && printf ',"remote":"%s"' "$(json_escape "$REMOTE")"
  printf ',"at":%s}\n' "$NOW_MS"
} >"$FILE.tmp.$$" 2>/dev/null || exit 0

# Atomic replace, so a reader never sees a half-written declaration.
mv -f "$FILE.tmp.$$" "$FILE" 2>/dev/null || {
  rm -f "$FILE.tmp.$$" 2>/dev/null || true
  exit 0
}

exit 0
