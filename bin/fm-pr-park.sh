#!/usr/bin/env bash
# Park a ship or scout worker whose only remaining wait is on an external
# change to one GitHub pull request - a maintainer review or merge, or a fork
# CI run that waits for maintainer approval - so the wait costs no session.
#
# Usage:
#   fm-pr-park.sh park <task-id> <pr-url>
#   fm-pr-park.sh unpark <task-id>
#   fm-pr-park.sh changed <task-id>
#   fm-pr-park.sh resume-note <task-id>
#
# park         Record the pull request's current fingerprint as the baseline in
#              state/<id>.park, arm the condition->action watch "park-<digest>"
#              (bin/fm-procevent-when.sh) that polls it every 300 seconds, then
#              stop the worker with `bin/fm-control.sh <id> exit`, which keeps
#              its endpoint, worktree, and every uncommitted change.
#              Refuses an unknown task, a secondmate, a pull request outside
#              GitHub, a task that is already parked, and a pull request whose
#              state cannot be read. When the watch cannot be armed or the
#              worker cannot be stopped, the park is rolled back and the worker
#              keeps its session.
# unpark       Retire the watch and remove the park record. Idempotent.
#              Run it after relaunching a parked worker and before re-parking.
# changed      The watch's condition: exit 0 when the fingerprint differs from
#              the baseline, 1 when it is unchanged, and 2 when the record or
#              the pull request cannot be read.
# resume-note  The watch's action: write data/<id>/park-resume.md, the
#              relaunch note that names the pull request and its baseline and
#              current fingerprints, and print its path.
#
# The watch name is park- followed by the first 54 hex digits of the SHA-256
# of the task id (without a newline); its source id is when-park-<digest>.
# On a wake, match the digest against task ids from state/*.park using that
# hash rule. If no park record matches, only acknowledge the result.
# Otherwise classify the result with fm-procevent-when.sh classify <result-file>.
# Only for fired, relaunch with `bin/fm-control.sh <id> relaunch --note-file
# data/<id>/park-resume.md`, then run `fm-pr-park.sh unpark <id>` and acknowledge.
# For condition-error, never-true (including deadline expiry), rejected, and
# every other non-fired outcome, use the existing when diagnostic handling in
# process-event-sources; keep the park record until recovery is decided.
# The relaunch stays a firstmate decision rather than the watch's action, so a
# relaunch refusal, such as a signed-out worker account, reaches firstmate
# instead of failing inside the watch.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
POLL_INTERVAL=300

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

die() { echo "error: fm-pr-park: $*" >&2; exit 1; }

usage() { sed -n '2,/^set -u/{ /^set -u/d; p; }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

watch_name() {
  local digest
  digest=$(printf '%s' "$1" | fm_pr_sha256 -) || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'park-%.54s\n' "$digest"
}

record_file() { printf '%s/%s.park\n' "$STATE" "$1"; }

valid_id() {
  fm_pr_task_id_valid "${1-}" || die "invalid task id: ${1-}"
}

# The jq program gh applies to the pull request. A check with a conclusion uses
# it; a status context uses its state; anything else is still pending.
# shellcheck disable=SC2016 # the $ names are jq variables, not shell expansions
FINGERPRINT_JQ='def result: ((.conclusion // "") | ascii_downcase) as $c
  | ((.state // "") | ascii_downcase) as $s
  | if $c != "" then $c elif ($s != "" and $s != "pending" and $s != "expected") then $s else "pending" end;
  [.state, .headRefOid, (.reviewDecision // ""), (.reviews | length | tostring),
   (.comments | length | tostring),
   ([.statusCheckRollup[]? | ((.name // .context // "") + "=" + result)] | sort | join(","))]
  | join(" ")'

fingerprint() {  # <github-pr-url>
  local out
  out=$(gh pr view "$1" --json state,headRefOid,reviewDecision,statusCheckRollup,comments,reviews \
    -q "$FINGERPRINT_JQ" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

github_url() {  # <pr-url>
  fm_pr_url_parse "$1" || die "not a canonical pull request URL: $1"
  [ "$FM_PR_PROVIDER" = github ] || die "only GitHub pull requests can be parked: $1"
}

# Read state/<id>.park into PARK_URL and PARK_BASELINE.
read_record() {  # <task-id>
  local file version _extra
  file=$(record_file "$1")
  PARK_URL=
  PARK_BASELINE=
  fm_pr_private_file_valid "$file" 600 "$(fm_pr_file_device "$STATE")" || return 1
  {
    IFS= read -r version || return 1
    IFS= read -r PARK_URL || return 1
    IFS= read -r PARK_BASELINE || return 1
    if IFS= read -r _extra; then return 1; fi
  } < "$file"
  [ "$version" = fm-pr-park-v1 ] && [ -n "$PARK_URL" ] && [ -n "$PARK_BASELINE" ]
}

cmd_changed() {
  local current
  [ "$#" -eq 1 ] || usage
  fm_pr_task_id_valid "$1" || exit 2
  read_record "$1" || exit 2
  current=$(fingerprint "$PARK_URL") || exit 2
  [ "$current" != "$PARK_BASELINE" ]
}

cmd_resume_note() {
  local id current note
  [ "$#" -eq 1 ] || usage
  id=$1
  valid_id "$id"
  read_record "$id" || die "no readable park record for $id"
  current=$(fingerprint "$PARK_URL") || current='(unreadable)'
  mkdir -p "$DATA/$id" || die "cannot create $DATA/$id"
  note="$DATA/$id/park-resume.md"
  {
    printf 'Your session was parked while you waited on an external change to %s.\n' "$PARK_URL"
    printf 'That pull request changed while you were parked.\n'
    printf 'Before: %s\n' "$PARK_BASELINE"
    printf 'Now: %s\n' "$current"
    # shellcheck disable=SC2016 # the backticks are literal Markdown
    printf 'Read the change, reattach to any active no-mistakes run with `no-mistakes axi run`, and continue the task under your brief.\n'
  } > "$note" || die "cannot write $note"
  printf '%s\n' "$note"
}

cmd_unpark() {
  [ "$#" -eq 1 ] || usage
  local name
  valid_id "$1"
  name=$(watch_name "$1") || die "cannot name the park watch for $1"
  "$SCRIPT_DIR/fm-procevent-when.sh" retire "$name" >/dev/null || die "cannot retire the park watch for $1"
  rm -f -- "$(record_file "$1")" || die "cannot remove the park record for $1"
  printf 'unparked: %s\n' "$1"
}

cmd_park() {
  local id url meta kind baseline file tmp name
  [ "$#" -eq 2 ] || usage
  id=$1
  url=$2
  valid_id "$id"
  name=$(watch_name "$id") || die "cannot name the park watch for $id"
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || die "no task record for $id in this home"
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in
    ship|scout) ;;
    *) die "only a ship or scout worker can be parked; $id is kind=${kind:-unknown}" ;;
  esac
  github_url "$url"
  file=$(record_file "$id")
  [ ! -e "$file" ] && [ ! -L "$file" ] || die "$id is already parked; unpark it first"
  baseline=$(fingerprint "$FM_PR_URL") || die "cannot read pull request $FM_PR_URL"
  tmp=$(umask 077; mktemp "$STATE/.fm-pr-park.XXXXXX") || die "cannot stage the park record"
  if ! { printf '%s\n%s\n%s\n' fm-pr-park-v1 "$FM_PR_URL" "$baseline" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$file"; }; then
    rm -f -- "$tmp"
    die "cannot write the park record for $id"
  fi
  if ! "$SCRIPT_DIR/fm-procevent-when.sh" arm "$name" --interval "$POLL_INTERVAL" --stable 1 \
    --condition "$SCRIPT_DIR/fm-pr-park.sh" changed "$id" \
    --action "$SCRIPT_DIR/fm-pr-park.sh" resume-note "$id" >/dev/null; then
    rm -f -- "$file"
    die "cannot arm the park watch for $id; the worker keeps its session"
  fi
  if ! "$SCRIPT_DIR/fm-control.sh" "$id" exit; then
    "$SCRIPT_DIR/fm-procevent-when.sh" retire "$name" >/dev/null 2>&1 || true
    rm -f -- "$file"
    die "cannot stop the worker for $id; the park was rolled back and the worker keeps its session"
  fi
  printf 'parked: %s on %s\n' "$id" "$FM_PR_URL"
}

case "${1:-}" in
  park) shift; cmd_park "$@" ;;
  unpark) shift; cmd_unpark "$@" ;;
  changed) shift; cmd_changed "$@" ;;
  resume-note) shift; cmd_resume_note "$@" ;;
  -h|--help) usage 0 ;;
  *) usage ;;
esac
