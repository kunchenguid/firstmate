#!/usr/bin/env bash
# fm-verified.sh - the durable per-home store of verification receipts, so that
# "is this verified?" is answered against an exact commit instead of prose.
#
# A verification result recorded only as a status line or a report carries no
# machine binding to the commit it covered, so a pass on an older commit reads
# as if it covered the current one. bin/fm-pr-merge.sh already refuses that
# shape for merges: a recorded pr_head that disagrees with the live head is
# reported rather than trusted, because a rebase moves the head and leaves the
# recorded value stale. This script gives a verifier's verdict the same binding.
#
# Usage:
#   fm-verified.sh record <subject> --head <sha> --verdict pass|fail [--evidence <path>] [--note <text>]
#   fm-verified.sh check <subject> --head <sha>
#   fm-verified.sh show <subject>
#   fm-verified.sh --help
#
# <subject> names what was verified - a task id, a branch, a component - as a
# path-safe slug ([A-Za-z0-9._-] with no leading dot). Its receipt is the single
# file $FM_HOME/state/verified/<subject>.receipt, replaced whole on every
# record, so a receipt is always the LATEST verification of that subject and
# never an append log. The file is a fm-verified-v1 marker line followed by
# subject=, head=, verdict=, and recorded= (UTC, second resolution), plus
# evidence= and note= when given. Both optional values must be one line.
# An --evidence path is recorded exactly as the caller wrote it and is never
# resolved, opened, or checked for existence: it is the caller's pointer to its
# own evidence, not a second thing this store verifies.
#
# <sha> is the exact commit the verification covered, 7 to 64 hexadecimal
# characters, matched case-insensitively and in full rather than by prefix.
# This script never resolves a head: it runs no git, reaches no network, and
# reads nothing but the receipt, so every answer is a comparison of two values
# that this caller and an earlier caller each named. A branch name, a tag, or
# HEAD is refused for that same reason, because none of them names one commit
# for longer than the next push. Recording a full sha and checking a short one
# is a head mismatch like any other, so use one spelling for both calls.
#
# check REQUIRES --head. There is deliberately no way to ask this store whether
# a subject is verified without naming the commit, because that unbound question
# is what produced an answer that was true about a commit nobody cared about.
# A recorded head that differs from the head asked about reports stale whatever
# its verdict says, because that verdict is about a different commit.
#
# check reads the receipt and nothing else. It never opens, echoes, or consults
# a status log, a report, or any other prose, so no wording anywhere can make an
# unverified head read as verified.
#
# check prints one line in a fixed field order:
#   <state>: subject=<subject> recorded-head=<sha|none> asked-head=<sha> recorded-verdict=<pass|fail|none> recorded-at=<utc|none>
# where <state> is verified, stale, never, or failed, matching the exit status
# below, so a caller can branch on the status without parsing that line.
#
# Environment: FM_HOME, FM_ROOT_OVERRIDE, and FM_STATE_OVERRIDE resolve the home
# exactly as the other bin/ scripts do.
#
# Exit status:
#   0  verified - a pass receipt recorded at exactly the head asked about; also
#      a successful record, a successful show, and --help
#   1  operational failure - the state directory or the receipt is unusable, or
#      the receipt could not be written
#   2  usage error - unknown verb, or a missing or malformed subject, head, or
#      verdict, including a check with no --head
#   3  stale - a receipt exists, but for a different head
#   4  never - no receipt for this subject; also a show with no receipt
#   5  failed - a fail receipt recorded at exactly the head asked about
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECEIPTS="$STATE/verified"
FM_VERIFIED_TMP=

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {  # <exit-code> <message>
  local code=$1
  shift
  printf 'fm-verified: %s\n' "$*" >&2
  exit "$code"
}

require_state_dir() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] \
    || die 1 "state directory is unavailable: $STATE"
  # A symlinked receipt directory would redirect every read and write out of
  # the home, which is a way to answer this question with someone else's bytes.
  { [ ! -e "$RECEIPTS" ] && [ ! -L "$RECEIPTS" ]; } || { [ -d "$RECEIPTS" ] && [ ! -L "$RECEIPTS" ]; } \
    || die 1 "receipt directory is unavailable: $RECEIPTS"
}

# Normalize a caller-named head to one comparable spelling, or refuse it.
# Hexadecimal only: a branch, a tag, or HEAD names whatever was last pushed
# there rather than one commit, which is the ambiguity this store exists to
# remove.
normalize_head() {  # <sha>
  local head=$1 LC_ALL=C
  head=$(printf '%s' "$head" | tr 'ABCDEF' 'abcdef')
  case "$head" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#head}" -ge 7 ] && [ "${#head}" -le 64 ] || return 1
  printf '%s' "$head"
}

require_one_line() {  # <label> <value>
  case "$2" in
    *$'\n'*|*$'\r'*) die 2 "$1 must be one line" ;;
  esac
}

receipt_path() {  # <subject>
  printf '%s/%s.receipt' "$RECEIPTS" "$1"
}

# Parse one receipt into RECEIPT_HEAD/RECEIPT_VERDICT/RECEIPT_AT. A file that is
# present but not a plain single-linked regular file, or that does not carry the
# marker line and all four required fields, is an operational failure rather
# than a verdict: reading a damaged receipt as "no receipt" would quietly turn
# a recorded fail into an invitation to re-verify.
read_receipt() {  # <file>
  local file=$1 line key value marker=
  RECEIPT_HEAD=
  RECEIPT_VERDICT=
  RECEIPT_AT=
  fm_pr_regular_destination_or_absent "$file" \
    || die 1 "receipt is unsafe to read: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      fm-verified-v1) marker=1; continue ;;
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) continue ;;
    esac
    case "$key" in
      head) RECEIPT_HEAD=$value ;;
      verdict) RECEIPT_VERDICT=$value ;;
      recorded) RECEIPT_AT=$value ;;
    esac
  done < "$file"
  [ -n "$marker" ] || die 1 "receipt is not a fm-verified-v1 record: $file"
  case "$RECEIPT_VERDICT" in
    pass|fail) : ;;
    *) die 1 "receipt has no usable verdict: $file" ;;
  esac
  [ -n "$RECEIPT_HEAD" ] && [ -n "$RECEIPT_AT" ] \
    || die 1 "receipt is missing its head or timestamp: $file"
}

cmd_record() {  # <subject> <flags...>
  local subject head='' verdict='' evidence='' note='' recorded file
  subject=${1-}
  fm_task_id_path_safe "$subject" \
    || die 2 "subject must be a path-safe slug: ${subject-}"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head) [ "$#" -ge 2 ] || die 2 "--head needs a value"; head=$2; shift 2 ;;
      --verdict) [ "$#" -ge 2 ] || die 2 "--verdict needs a value"; verdict=$2; shift 2 ;;
      --evidence) [ "$#" -ge 2 ] || die 2 "--evidence needs a value"; evidence=$2; shift 2 ;;
      --note) [ "$#" -ge 2 ] || die 2 "--note needs a value"; note=$2; shift 2 ;;
      *) die 2 "unknown record argument: $1" ;;
    esac
  done
  [ -n "$head" ] || die 2 "record needs --head <sha>"
  head=$(normalize_head "$head") \
    || die 2 "--head must be 7 to 64 hexadecimal characters naming one commit"
  case "$verdict" in
    pass|fail) : ;;
    '') die 2 "record needs --verdict pass|fail" ;;
    *) die 2 "--verdict must be pass or fail: $verdict" ;;
  esac
  require_one_line --evidence "$evidence"
  require_one_line --note "$note"

  require_state_dir
  umask 077
  mkdir -p "$RECEIPTS" || die 1 "could not create $RECEIPTS"
  file=$(receipt_path "$subject")
  fm_pr_regular_destination_or_absent "$file" \
    || die 1 "receipt path is unsafe to replace: $file"
  recorded=$(date -u +%Y-%m-%dT%H:%M:%SZ) || die 1 "could not read the clock"
  FM_VERIFIED_TMP=$(mktemp "$RECEIPTS/.fm-verified.XXXXXX") || die 1 "could not stage the receipt"
  trap '[ -z "$FM_VERIFIED_TMP" ] || rm -f -- "$FM_VERIFIED_TMP"' EXIT HUP INT TERM
  {
    printf 'fm-verified-v1\n'
    printf 'subject=%s\n' "$subject"
    printf 'head=%s\n' "$head"
    printf 'verdict=%s\n' "$verdict"
    printf 'recorded=%s\n' "$recorded"
    [ -z "$evidence" ] || printf 'evidence=%s\n' "$evidence"
    [ -z "$note" ] || printf 'note=%s\n' "$note"
  } > "$FM_VERIFIED_TMP" || die 1 "could not write the receipt"
  chmod 0600 "$FM_VERIFIED_TMP" || die 1 "could not secure the receipt"
  # Re-check immediately before the replace: the staged bytes are ours, but the
  # destination could have become a link since the check above.
  fm_pr_regular_destination_or_absent "$file" \
    || die 1 "receipt path is unsafe to replace: $file"
  mv -f -- "$FM_VERIFIED_TMP" "$file" || die 1 "could not replace the receipt"
  FM_VERIFIED_TMP=
  printf 'recorded: %s verdict=%s head=%s at=%s\n' "$subject" "$verdict" "$head" "$recorded"
}

cmd_check() {  # <subject> --head <sha>
  local subject head='' file state code
  subject=${1-}
  fm_task_id_path_safe "$subject" \
    || die 2 "subject must be a path-safe slug: ${subject-}"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head) [ "$#" -ge 2 ] || die 2 "--head needs a value"; head=$2; shift 2 ;;
      *) die 2 "unknown check argument: $1" ;;
    esac
  done
  [ -n "$head" ] \
    || die 2 "check needs --head <sha>: a verification is only ever true of one commit"
  head=$(normalize_head "$head") \
    || die 2 "--head must be 7 to 64 hexadecimal characters naming one commit"

  require_state_dir
  file=$(receipt_path "$subject")
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    state=never
    code=4
    RECEIPT_HEAD=none
    RECEIPT_VERDICT=none
    RECEIPT_AT=none
  else
    read_receipt "$file"
    if [ "$RECEIPT_HEAD" != "$head" ]; then
      state=stale
      code=3
    elif [ "$RECEIPT_VERDICT" = pass ]; then
      state=verified
      code=0
    else
      state=failed
      code=5
    fi
  fi
  printf '%s: subject=%s recorded-head=%s asked-head=%s recorded-verdict=%s recorded-at=%s\n' \
    "$state" "$subject" "$RECEIPT_HEAD" "$head" "$RECEIPT_VERDICT" "$RECEIPT_AT"
  exit "$code"
}

cmd_show() {  # <subject>
  local subject file
  subject=${1-}
  fm_task_id_path_safe "$subject" \
    || die 2 "subject must be a path-safe slug: ${subject-}"
  [ "$#" -le 1 ] || die 2 "show takes only <subject>"
  require_state_dir
  file=$(receipt_path "$subject")
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'never: subject=%s has no verification receipt\n' "$subject"
    exit 4
  fi
  fm_pr_regular_destination_or_absent "$file" \
    || die 1 "receipt is unsafe to read: $file"
  cat -- "$file" || die 1 "could not read the receipt: $file"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
VERB=$1
shift
case "$VERB" in
  record) cmd_record "$@" ;;
  check) cmd_check "$@" ;;
  show) cmd_show "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
