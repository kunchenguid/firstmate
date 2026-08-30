#!/usr/bin/env bash
# Own durable, exclusive Linear ticket-writer assignments and role briefs.
#
# Usage:
#   fm-linear-ticket-writer.sh assign <issue-id> <identifier> <url> <task-id> <writer-id>
#   fm-linear-ticket-writer.sh transfer <identifier> <expected-writer-id> <new-writer-id>
#   fm-linear-ticket-writer.sh assert-writer <identifier> <task-id> <writer-id>
#   fm-linear-ticket-writer.sh assert-target <identifier> <task-id> <writer-id> <target-identifier>
#   fm-linear-ticket-writer.sh owner-brief <identifier> <task-id> <writer-id>
#   fm-linear-ticket-writer.sh planner-brief <identifier> <task-id>
#   fm-linear-ticket-writer.sh show <identifier>
#
# Firstmate owns these records. A ticket worker reads and proves its assignment,
# but never edits the lease or Firstmate backlog directly. Replacing a worker is
# an explicit transfer that rewrites the current lease and appends a durable
# history row while holding the assignment lock.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEASE_DIR="$STATE/linear-ticket-writers"
LOCK="$LEASE_DIR/.lock"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

valid_identifier() { [[ ${1-} =~ ^[A-Z][A-Z0-9]*-[1-9][0-9]*$ ]]; }
valid_actor() { fm_task_id_path_safe "${1-}"; }
valid_issue_id() { [ -n "${1-}" ] && [[ ${1-} != *$'\n'* ]]; }
valid_url() { [[ ${1-} == https://linear.app/* ]] && [[ ${1-} != *$'\n'* ]]; }

lease_path() { printf '%s/%s.lease\n' "$LEASE_DIR" "$1"; }
history_path() { printf '%s/%s.history\n' "$LEASE_DIR" "$1"; }

prepare_dir() {
  (umask 077; mkdir -p "$LEASE_DIR") || die "cannot create Linear writer state directory"
  [ -d "$LEASE_DIR" ] && [ ! -L "$LEASE_DIR" ] || die "unsafe Linear writer state directory"
  chmod 700 "$LEASE_DIR" || die "cannot secure Linear writer state directory"
}

lock_acquire() {
  prepare_dir
  fm_lock_acquire_wait "$LOCK" || die "cannot lock Linear writer assignments"
}

lock_release() { fm_lock_release "$LOCK"; }

load_lease() { # <identifier>
  local identifier=$1 file issue task writer issue_id url generation extra
  file=$(lease_path "$identifier")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  {
    IFS= read -r issue
    IFS= read -r task
    IFS= read -r writer
    IFS= read -r issue_id
    IFS= read -r url
    IFS= read -r generation
    ! IFS= read -r extra
  } < "$file" || return 2
  issue=${issue#issue=}
  task=${task#task=}
  writer=${writer#writer=}
  issue_id=${issue_id#issue_id=}
  url=${url#url=}
  generation=${generation#generation=}
  [ "$issue" = "$identifier" ] && valid_actor "$task" && valid_actor "$writer" \
    && valid_issue_id "$issue_id" && valid_url "$url" \
    && [[ $generation =~ ^[1-9][0-9]*$ ]] || return 2
  LINEAR_LEASE_TASK=$task
  LINEAR_LEASE_WRITER=$writer
  LINEAR_LEASE_ISSUE_ID=$issue_id
  LINEAR_LEASE_URL=$url
  LINEAR_LEASE_GENERATION=$generation
}

write_lease_locked() { # <identifier> <issue-id> <url> <task> <writer> <generation>
  local identifier=$1 issue_id=$2 url=$3 task=$4 writer=$5 generation=$6 file staged
  file=$(lease_path "$identifier")
  staged=$(mktemp "$LEASE_DIR/.lease.XXXXXX") || return 1
  if printf 'issue=%s\ntask=%s\nwriter=%s\nissue_id=%s\nurl=%s\ngeneration=%s\n' \
    "$identifier" "$task" "$writer" "$issue_id" "$url" "$generation" > "$staged" \
    && chmod 600 "$staged" && mv "$staged" "$file"; then
    return 0
  fi
  rm -f "$staged"
  return 1
}

task_has_other_lease_locked() { # <task> <except-identifier>
  local task=$1 except=$2 file identifier
  for file in "$LEASE_DIR"/*.lease; do
    [ -e "$file" ] || continue
    identifier=${file##*/}
    identifier=${identifier%.lease}
    [ "$identifier" = "$except" ] && continue
    load_lease "$identifier" || return 0
    [ "$LINEAR_LEASE_TASK" != "$task" ] || return 0
  done
  return 1
}

cmd_assign() {
  local issue_id=${1-} identifier=${2-} url=${3-} task=${4-} writer=${5-} status
  [ "$#" -eq 5 ] || usage
  valid_issue_id "$issue_id" || die "invalid immutable Linear issue id"
  valid_identifier "$identifier" || die "invalid Linear identifier: $identifier"
  valid_url "$url" || die "invalid canonical Linear URL"
  valid_actor "$task" || die "invalid Firstmate task id: $task"
  valid_actor "$writer" || die "invalid writer id: $writer"
  lock_acquire
  status=0
  if load_lease "$identifier"; then
    if [ "$LINEAR_LEASE_ISSUE_ID" = "$issue_id" ] && [ "$LINEAR_LEASE_URL" = "$url" ] \
      && [ "$LINEAR_LEASE_TASK" = "$task" ] && [ "$LINEAR_LEASE_WRITER" = "$writer" ]; then
      printf 'already-assigned: issue=%s task=%s writer=%s\n' "$identifier" "$task" "$writer"
    else
      status=1
    fi
  elif [ "$?" -eq 2 ] || task_has_other_lease_locked "$task" "$identifier"; then
    status=1
  elif write_lease_locked "$identifier" "$issue_id" "$url" "$task" "$writer" 1; then
    printf '%s\tassign\tissue=%s\ttask=%s\twriter=%s\tgeneration=1\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$identifier" "$task" "$writer" >> "$(history_path "$identifier")"
    chmod 600 "$(history_path "$identifier")"
    printf 'assigned: issue=%s task=%s writer=%s\n' "$identifier" "$task" "$writer"
  else
    status=1
  fi
  lock_release
  [ "$status" -eq 0 ] || die "Linear ticket already has a different writer or task assignment: $identifier"
}

cmd_transfer() {
  local identifier=${1-} expected=${2-} replacement=${3-} generation status=0
  [ "$#" -eq 3 ] || usage
  valid_identifier "$identifier" || die "invalid Linear identifier: $identifier"
  valid_actor "$expected" || die "invalid expected writer id: $expected"
  valid_actor "$replacement" || die "invalid replacement writer id: $replacement"
  [ "$expected" != "$replacement" ] || die "replacement writer must differ from current writer"
  lock_acquire
  if ! load_lease "$identifier" || [ "$LINEAR_LEASE_WRITER" != "$expected" ]; then
    status=1
  else
    generation=$((LINEAR_LEASE_GENERATION + 1))
    write_lease_locked "$identifier" "$LINEAR_LEASE_ISSUE_ID" "$LINEAR_LEASE_URL" \
      "$LINEAR_LEASE_TASK" "$replacement" "$generation" || status=1
    if [ "$status" -eq 0 ]; then
      printf '%s\ttransfer\tissue=%s\ttask=%s\tfrom=%s\twriter=%s\tgeneration=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$identifier" "$LINEAR_LEASE_TASK" \
        "$expected" "$replacement" "$generation" >> "$(history_path "$identifier")"
      chmod 600 "$(history_path "$identifier")"
      printf 'transferred: issue=%s task=%s writer=%s generation=%s\n' \
        "$identifier" "$LINEAR_LEASE_TASK" "$replacement" "$generation"
    fi
  fi
  lock_release
  [ "$status" -eq 0 ] || die "writer transfer refused; expected writer does not hold ticket: $identifier"
}

assert_writer() { # <identifier> <task> <writer>
  local identifier=$1 task=$2 writer=$3
  if ! valid_identifier "$identifier" || ! valid_actor "$task" || ! valid_actor "$writer"; then
    die "invalid writer assertion"
  fi
  load_lease "$identifier" || die "no valid writer assignment for $identifier"
  [ "$LINEAR_LEASE_TASK" = "$task" ] && [ "$LINEAR_LEASE_WRITER" = "$writer" ] \
    || die "Linear write authority denied for $identifier"
}

cmd_assert_writer() {
  [ "$#" -eq 3 ] || usage
  assert_writer "$1" "$2" "$3"
  printf 'writer-authorized: issue=%s task=%s writer=%s\n' "$1" "$2" "$3"
}

cmd_assert_target() {
  [ "$#" -eq 4 ] || usage
  assert_writer "$1" "$2" "$3"
  [ "$1" = "$4" ] || die "assigned writer for $1 may not update $4"
  printf 'target-authorized: issue=%s task=%s writer=%s\n' "$1" "$2" "$3"
}

append_brief_section() { # <brief> <marker> <body>
  local brief=$1 marker=$2 body=$3 staged mode
  [ -f "$brief" ] && [ ! -L "$brief" ] || die "task brief does not exist: $brief"
  if grep -Fqx "$marker" "$brief"; then
    die "task brief already contains $marker"
  fi
  mode=$(fm_pr_file_mode "$brief") || die "cannot read task brief mode"
  staged=$(mktemp "${brief%/*}/.brief.XXXXXX") || die "cannot stage task brief"
  if { cat "$brief"; printf '\n%s\n%s\n' "$marker" "$body"; } > "$staged" \
    && chmod "$mode" "$staged" \
    && mv "$staged" "$brief"; then
    return 0
  fi
  rm -f "$staged"
  die "cannot update task brief"
}

replace_owner_assertion() { # <brief> <replacement-line>
  local brief=$1 replacement=$2 staged mode count
  mode=$(fm_pr_file_mode "$brief") || die "cannot read task brief mode"
  count=$(grep -c '^Before every Linear mutation, run:' "$brief" || true)
  [ "$count" -eq 1 ] || die "existing owner brief has an invalid writer assertion"
  staged=$(mktemp "${brief%/*}/.brief.XXXXXX") || die "cannot stage task brief"
  if awk -v replacement="$replacement" '
      /^Before every Linear mutation, run:/ { print replacement; next }
      { print }
    ' "$brief" > "$staged" && chmod "$mode" "$staged" && mv "$staged" "$brief"; then
    return 0
  fi
  rm -f "$staged"
  die "cannot update task brief"
}

cmd_owner_brief() {
  local identifier=${1-} task=${2-} writer=${3-} brief body assertion
  [ "$#" -eq 3 ] || usage
  assert_writer "$identifier" "$task" "$writer"
  brief="$DATA/$task/brief.md"
  assertion="Before every Linear mutation, run: bin/fm-linear-ticket-writer.sh assert-target $identifier $task $writer <target-identifier>"
  body=$(printf '%s\n' \
    "You are the sole Linear writer for $identifier." \
    "You may update only $identifier." \
    "$assertion" \
    "Use Linear MCP for ticket status, comments, and Workpad updates." \
    "Create or update exactly one \`## Firstmate Workpad\` on $identifier." \
    "Record the accepted plan, progress, blockers, PR URL, review outcomes, and fixes on $identifier." \
    "Do not update another Linear issue." \
    "Do not modify Firstmate's local backlog directly." \
    "Do not mark the ticket Done until its PR is verified merged." \
    "If Linear MCP is unavailable, report a blocker; the poller never becomes a fallback writer.")
  if grep -Fqx "# Linear ticket ownership" "$brief"; then
    replace_owner_assertion "$brief" "$assertion"
  else
    append_brief_section "$brief" "# Linear ticket ownership" "$body"
  fi
  printf 'owner-brief: %s\n' "$brief"
}

cmd_planner_brief() {
  local identifier=${1-} task=${2-} brief body
  [ "$#" -eq 2 ] || usage
  valid_identifier "$identifier" || die "invalid Linear identifier: $identifier"
  valid_actor "$task" || die "invalid Firstmate task id: $task"
  brief="$DATA/$task/brief.md"
  body=$(printf '%s\n' \
    "You are planning or reviewing $identifier, but you hold no Linear write authority." \
    "Do not create comments, edit the Workpad, change status, change assignment, or perform any other Linear mutation." \
    "Report plans and review findings through Firstmate so the assigned ticket owner can record them in Linear.")
  append_brief_section "$brief" "# Linear write restriction" "$body"
  printf 'planner-brief: %s\n' "$brief"
}

cmd_show() {
  local identifier=${1-}
  [ "$#" -eq 1 ] || usage
  valid_identifier "$identifier" || die "invalid Linear identifier: $identifier"
  load_lease "$identifier" || die "no valid writer assignment for $identifier"
  cat "$(lease_path "$identifier")"
}

case "${1-}" in
  assign) shift; cmd_assign "$@" ;;
  transfer) shift; cmd_transfer "$@" ;;
  assert-writer) shift; cmd_assert_writer "$@" ;;
  assert-target) shift; cmd_assert_target "$@" ;;
  owner-brief) shift; cmd_owner_brief "$@" ;;
  planner-brief) shift; cmd_planner_brief "$@" ;;
  show) shift; cmd_show "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
