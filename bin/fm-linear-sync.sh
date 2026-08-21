#!/usr/bin/env bash
# fm-linear-sync.sh - durable Linear synchronization for firstmate work.
#
# Enforces one captain rule mechanically: work is not complete until the
# corresponding Linear issue is current. A task is explicitly BOUND to one or
# more Linear issues; every handback is queued as a typed durable record; a
# delivery is idempotent across retries, crashes, compaction, and restart; and
# bin/fm-teardown.sh refuses to clean a task up while it still owes one.
#
# Nothing here ever infers a target. There is no transcript scraping and no
# prose matching: an unbound task refuses, an ambiguous binding refuses, and a
# comment is exactly the bytes the caller supplied.
#
# bin/fm-linear-lib.sh owns the gate order, the private layout, and the derived
# delivery identity. This script owns the commands, flags, and the delivery
# sequence that survives the lost-ack interval.
#
# Usage:
#   fm-linear-sync.sh bind <task-id> <issue-ref>...
#   fm-linear-sync.sh unbind <task-id> [<issue-ref>]
#   fm-linear-sync.sh bindings [<task-id>]
#   fm-linear-sync.sh queue <task-id> (--comment-file <path> | --comment-stdin)
#                          [--issue <ref>] [--status <workflow-state-name>]
#   fm-linear-sync.sh pending [<task-id>]
#   fm-linear-sync.sh show <delivery-id>
#   fm-linear-sync.sh deliver (<delivery-id> | --task <task-id> | --all)
#   fm-linear-sync.sh guard-work <task-id>
#   fm-linear-sync.sh discard <delivery-id> --reason <text> --yes
#   fm-linear-sync.sh hook
#   fm-linear-sync.sh status
#
# An <issue-ref> is the identifier a captain types (TEAM-123) or the API UUID.
# A --status is a Linear workflow state NAME exactly as the team spells it
# ("In Progress", "Done"); omit it to post a comment and change nothing else.
#
# Exit status:
#   0  the command succeeded
#   1  a refusal: a missing or ambiguous target, an invalid argument, an
#      unfinished handback found by guard-work, or a delivery Linear rejected
#   2  usage
#   3  a hold: Linear is not configured or not reachable, so the handback is
#      preserved untouched and must be retried. Never a completion.
#
# `hook` is the passive integration surface. It is scoped to a genuine firstmate
# primary home (bin/fm-primary-scope-lib.sh) and prints nothing at all in an
# ordinary project repo, in a crewmate/scout task worktree, or in a home with no
# Linear bindings, so it is safe to wire into any harness lifecycle surface.
# No harness hook file ships it enabled; docs/linear-sync.md owns why.
#
# Delivery sequence (the part that must survive a lost acknowledgement):
#   1. an existing local receipt short-circuits;
#   2. otherwise the issue's own comments are read back and searched for this
#      delivery's marker, which is Linear's authoritative copy of the fact that
#      the comment landed. A truncated read-back is treated as UNKNOWN and holds
#      rather than posting, so a very long issue cannot produce a duplicate;
#   3. only a proven absence posts the comment;
#   4. an optional status change is applied only when the issue is not already
#      in that state, and is confirmed by reading the state back;
#   5. the receipt is written last. A crash anywhere before it converges on the
#      next run through step 2, with no second comment and no second status
#      change.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-linear-lib.sh
. "$SCRIPT_DIR/fm-linear-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-linear-sync: %s\n' "$*" >&2
  exit 1
}

usage_die() {
  printf 'fm-linear-sync: %s\n' "$*" >&2
  usage
  exit 2
}

hold_exit() {
  printf 'fm-linear-sync: %s\n' "$*" >&2
  exit 3
}

now_epoch() { date +%s; }

require_jq() {
  command -v jq >/dev/null 2>&1 \
    || hold_exit 'jq is required to build and read typed Linear records'
}

# Every mutating verb runs in a genuine primary home. A crewmate/scout worktree
# and a plain project clone both refuse loudly here rather than creating state
# in the wrong place; `hook` is the one caller that stays silent instead.
require_primary_home() {
  fm_linear_home_scoped "$FM_HOME" "$STATE" \
    || die "$FM_HOME is not a firstmate primary home; Linear synchronization is inert here"
}

TMP_FILES=()
cleanup_tmp() {
  local f
  for f in "${TMP_FILES[@]+"${TMP_FILES[@]}"}"; do
    [ -z "$f" ] || rm -f -- "$f"
  done
}
trap cleanup_tmp EXIT

new_tmp() {
  local f
  f=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-linear.XXXXXX") || return 1
  TMP_FILES+=("$f")
  printf '%s\n' "$f"
}

# --- bind / unbind / bindings ----------------------------------------------

cmd_bind() {
  local task=${1-} issue dir file existing tmp
  shift || true
  [ -n "$task" ] || usage_die 'bind needs a task id'
  [ "$#" -ge 1 ] || usage_die 'bind needs at least one issue reference'
  fm_linear_slug_valid "$task" || die "not a usable task id: $task"
  require_primary_home
  for issue in "$@"; do
    fm_linear_issue_ref_valid "$issue" \
      || die "not a Linear issue reference: $issue (expected TEAM-123 or an API UUID)"
  done

  dir=$(fm_linear_bindings_dir "$STATE")
  file="$dir/$task"
  existing=$(fm_linear_binding_issues "$STATE" "$task")
  tmp=$(new_tmp) || die 'cannot create a temporary file'
  {
    printf 'bound_at=%s\n' "$(now_epoch)"
    {
      [ -z "$existing" ] || printf '%s\n' "$existing"
      printf '%s\n' "$@"
    } | LC_ALL=C sort -u | while IFS= read -r issue; do
      [ -n "$issue" ] || continue
      printf 'issue=%s\n' "$issue"
    done
  } > "$tmp"
  fmx_private_artifact_publish_stdin "$dir" "$task" 600 < "$tmp" \
    || die "cannot record the binding at $file"
  printf 'bound %s ->' "$task"
  fm_linear_binding_issues "$STATE" "$task" | while IFS= read -r issue; do
    printf ' %s' "$issue"
  done
  printf '\n'
}

cmd_unbind() {
  local task=${1-} issue=${2-} dir file kept tmp
  [ -n "$task" ] || usage_die 'unbind needs a task id'
  fm_linear_slug_valid "$task" || die "not a usable task id: $task"
  require_primary_home
  dir=$(fm_linear_bindings_dir "$STATE")
  file="$dir/$task"
  [ -f "$file" ] && [ ! -L "$file" ] || die "task $task has no Linear binding"
  if [ -n "$(fm_linear_pending_deliveries "$STATE" "$task")" ]; then
    die "task $task still owes a Linear handback; deliver or discard it before unbinding"
  fi
  if [ -z "$issue" ]; then
    rm -f -- "$file"
    printf 'unbound %s\n' "$task"
    return 0
  fi
  fm_linear_issue_ref_valid "$issue" || die "not a Linear issue reference: $issue"
  kept=$(fm_linear_binding_issues "$STATE" "$task" | grep -Fxv -- "$issue" || true)
  if [ -z "$kept" ]; then
    rm -f -- "$file"
    printf 'unbound %s\n' "$task"
    return 0
  fi
  tmp=$(new_tmp) || die 'cannot create a temporary file'
  {
    printf 'bound_at=%s\n' "$(now_epoch)"
    printf '%s\n' "$kept" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf 'issue=%s\n' "$line"
    done
  } > "$tmp"
  fmx_private_artifact_publish_stdin "$dir" "$task" 600 < "$tmp" \
    || die "cannot rewrite the binding at $file"
  printf 'unbound %s from %s\n' "$issue" "$task"
}

cmd_bindings() {
  local task=${1-} t issues
  fm_linear_present "$STATE" || return 0
  if [ -n "$task" ]; then
    fm_linear_slug_valid "$task" || die "not a usable task id: $task"
    issues=$(fm_linear_binding_issues "$STATE" "$task")
    [ -n "$issues" ] || return 0
    printf '%s' "$task"
    printf '%s\n' "$issues" | while IFS= read -r i; do printf ' %s' "$i"; done
    printf '\n'
    return 0
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    cmd_bindings "$t"
  done < <(fm_linear_bound_tasks "$STATE")
}

# --- queue ------------------------------------------------------------------

# Resolve the one issue this handback targets. This is the refusal the whole
# design rests on: no binding refuses, and more than one bound issue with no
# explicit --issue refuses as ambiguous rather than picking the first.
resolve_issue() {  # <task> <explicit-issue-or-empty>
  local task=$1 explicit=$2 issues count
  issues=$(fm_linear_binding_issues "$STATE" "$task")
  if [ -z "$issues" ]; then
    die "task $task has no Linear issue binding; bind it first with: $(basename "$0") bind $task <issue-ref>"
  fi
  if [ -n "$explicit" ]; then
    fm_linear_issue_ref_valid "$explicit" || die "not a Linear issue reference: $explicit"
    printf '%s\n' "$issues" | grep -Fxq -- "$explicit" \
      || die "issue $explicit is not bound to task $task; bound: $(printf '%s' "$issues" | tr '\n' ' ')"
    printf '%s\n' "$explicit"
    return 0
  fi
  count=$(printf '%s\n' "$issues" | grep -c . || true)
  if [ "$count" -ne 1 ]; then
    die "task $task is bound to $count Linear issues; name one with --issue (bound: $(printf '%s' "$issues" | tr '\n' ' '))"
  fi
  printf '%s\n' "$issues"
}

cmd_queue() {
  local task=${1-} comment_file='' comment_stdin=0 explicit_issue='' status=''
  local issue canonical trimmed delivery_id record marker rc length
  shift || true
  [ -n "$task" ] || usage_die 'queue needs a task id'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --comment-file) [ "$#" -gt 1 ] || usage_die '--comment-file needs a path'; comment_file=$2; shift 2 ;;
      --comment-stdin) comment_stdin=1; shift ;;
      --issue) [ "$#" -gt 1 ] || usage_die '--issue needs a reference'; explicit_issue=$2; shift 2 ;;
      --status) [ "$#" -gt 1 ] || usage_die '--status needs a workflow state name'; status=$2; shift 2 ;;
      *) usage_die "unknown queue option: $1" ;;
    esac
  done
  fm_linear_slug_valid "$task" || die "not a usable task id: $task"
  require_primary_home
  require_jq
  if [ -n "$comment_file" ] && [ "$comment_stdin" -eq 1 ]; then
    usage_die 'use either --comment-file or --comment-stdin, not both'
  fi
  if [ -z "$comment_file" ] && [ "$comment_stdin" -eq 0 ]; then
    usage_die 'queue needs --comment-file <path> or --comment-stdin'
  fi
  if [ -n "$status" ]; then
    fm_linear_status_valid "$status" || die 'not a usable Linear workflow state name'
  fi

  issue=$(resolve_issue "$task" "$explicit_issue") || exit 1

  canonical=$(new_tmp) || die 'cannot create a temporary file'
  if [ "$comment_stdin" -eq 1 ]; then
    cat > "$canonical"
  else
    [ -f "$comment_file" ] || die "comment file not found: $comment_file"
    cat -- "$comment_file" > "$canonical"
  fi
  # Canonicalize the trailing newline only. Everything else reaches Linear
  # byte-exact, because the comment is the captain's text, not a summary.
  trimmed=$(new_tmp) || die 'cannot create a temporary file'
  if ! printf '%s' "$(cat "$canonical")" > "$trimmed"; then
    die 'cannot canonicalize the comment'
  fi
  mv -f "$trimmed" "$canonical" || die 'cannot canonicalize the comment'
  [ -s "$canonical" ] || die 'the comment is empty; refusing to post nothing'
  if grep -Fq -- "$FM_LINEAR_MARKER_PREFIX" "$canonical"; then
    die "the comment contains the reserved marker prefix '$FM_LINEAR_MARKER_PREFIX'; refusing"
  fi
  # tr understands the octal escapes a portable grep does not, so the check is a
  # byte comparison against the same text with control characters removed.
  # Tab, newline, and carriage return are deliberately not in that set.
  if ! LC_ALL=C cmp -s "$canonical" \
      <(LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' < "$canonical"); then
    die 'the comment contains control characters; refusing'
  fi
  length=$(jq -Rs 'length' < "$canonical") || die 'cannot measure the comment'
  [ "$length" -le "$FM_LINEAR_COMMENT_MAX" ] \
    || die "the comment is $length characters, over the $FM_LINEAR_COMMENT_MAX limit"

  delivery_id=$(fm_linear_delivery_id "$task" "$issue" "$status" "$canonical") \
    || die 'cannot derive the delivery identity'
  marker=$(fm_linear_marker "$delivery_id")

  if fmx_private_artifact_file_valid "$(fm_linear_sent_dir "$STATE")" "$delivery_id" 600; then
    printf 'already delivered: %s -> %s (%s)\n' "$task" "$issue" "$delivery_id"
    return 0
  fi
  if fmx_private_artifact_file_valid "$(fm_linear_refused_dir "$STATE")" "$delivery_id.json" 600; then
    printf 'already queued and refused by Linear: %s (see: %s show %s)\n' \
      "$delivery_id" "$(basename "$0")" "$delivery_id" >&2
    return 1
  fi

  record=$(new_tmp) || die 'cannot create a temporary file'
  jq -n \
    --arg schema "$FM_LINEAR_DELIVERY_SCHEMA" \
    --arg delivery_id "$delivery_id" \
    --arg task_id "$task" \
    --arg issue "$issue" \
    --rawfile comment "$canonical" \
    --arg status "$status" \
    --arg marker "$marker" \
    --argjson queued_at "$(now_epoch)" \
    '{schema:$schema, delivery_id:$delivery_id, task_id:$task_id, issue:$issue,
      comment:$comment, status:(if $status == "" then null else $status end),
      marker:$marker, queued_at:$queued_at}' > "$record" \
    || die 'cannot build the typed delivery record'

  fmx_private_artifact_publish_stdin_once \
    "$(fm_linear_outbox_dir "$STATE")" "$delivery_id.json" 600 < "$record"
  rc=$?
  case "$rc" in
    0) printf 'queued %s -> %s (%s)\n' "$task" "$issue" "$delivery_id" ;;
    1) printf 'already queued %s -> %s (%s)\n' "$task" "$issue" "$delivery_id" ;;
    *) die 'cannot record the delivery' ;;
  esac
}

# --- pending / show / guard-work / hook / status ----------------------------

pending_line() {  # <delivery-id>
  local id=$1 outbox refused file task issue status state reason attempts next
  outbox="$(fm_linear_outbox_dir "$STATE")/$id.json"
  refused="$(fm_linear_refused_dir "$STATE")/$id.json"
  if [ -f "$outbox" ] && [ ! -L "$outbox" ]; then
    file=$outbox
    state=queued
  elif [ -f "$refused" ] && [ ! -L "$refused" ]; then
    file=$refused
    state=refused
  else
    return 1
  fi
  task=$(fm_linear_record_field "$file" task_id) || task='?'
  issue=$(fm_linear_record_field "$file" issue) || issue='?'
  status=$(fm_linear_record_field "$file" status) || status=
  reason=
  if [ "$state" = refused ]; then
    reason=$(head -c 400 "$(fm_linear_refused_dir "$STATE")/$id.reason" 2>/dev/null | fm_linear_clean_line)
  else
    attempts="$(fm_linear_attempts_dir "$STATE")/$id"
    if [ -f "$attempts" ] && [ ! -L "$attempts" ]; then
      reason=$(grep -m1 '^reason=' "$attempts" 2>/dev/null | cut -d= -f2- | fm_linear_clean_line)
      next=$(grep -m1 '^next_attempt=' "$attempts" 2>/dev/null | cut -d= -f2-)
      [ -z "$next" ] || reason="$reason (retry after epoch $next)"
    fi
  fi
  printf '%s  task=%s  issue=%s  status=%s  delivery=%s' \
    "$state" "$task" "$issue" "${status:--}" "$id"
  [ -z "$reason" ] || printf '  reason=%s' "$reason"
  printf '\n'
}

cmd_pending() {
  local task=${1-} id
  fm_linear_present "$STATE" || return 0
  [ -z "$task" ] || fm_linear_slug_valid "$task" || die "not a usable task id: $task"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    pending_line "$id" || true
  done < <(fm_linear_pending_deliveries "$STATE" "$task")
}

cmd_show() {
  local id=${1-} file
  [ -n "$id" ] || usage_die 'show needs a delivery id'
  fm_linear_slug_valid "$id" || die "not a usable delivery id: $id"
  for file in \
    "$(fm_linear_outbox_dir "$STATE")/$id.json" \
    "$(fm_linear_refused_dir "$STATE")/$id.json"; do
    if [ -f "$file" ] && [ ! -L "$file" ]; then
      cat -- "$file"
      [ -f "${file%.json}.reason" ] && cat -- "${file%.json}.reason"
      return 0
    fi
  done
  for file in \
    "$(fm_linear_sent_dir "$STATE")/$id" \
    "$(fm_linear_discarded_dir "$STATE")/$id"; do
    if [ -f "$file" ] && [ ! -L "$file" ]; then
      cat -- "$file"
      return 0
    fi
  done
  die "no Linear delivery record for $id"
}

# guard-work is the completion gate bin/fm-teardown.sh calls. Exit 1 with the
# blocking lines on stdout when this task still owes a handback; silent exit 0
# otherwise. Costs one [ -d ] test in a home that never bound an issue.
cmd_guard_work() {
  local task=${1-} found=0 id
  [ -n "$task" ] || usage_die 'guard-work needs a task id'
  fm_linear_slug_valid "$task" || return 0
  fm_linear_present "$STATE" || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    found=1
    pending_line "$id" || true
  done < <(fm_linear_pending_deliveries "$STATE" "$task")
  [ "$found" -eq 0 ]
}

# The passive integration surface. Silent everywhere it does not apply.
cmd_hook() {
  local count
  fm_linear_present "$STATE" || return 0
  fm_linear_home_scoped "$FM_HOME" "$STATE" || return 0
  fm_linear_has_pending "$STATE" || return 0
  count=$(fm_linear_pending_deliveries "$STATE" | grep -c . || true)
  printf 'Linear: %s handback(s) still owed; work bound to those issues is not complete.\n' "$count" >&2
  printf 'Run %s/bin/fm-linear-sync.sh pending to see them, then deliver --all.\n' "$FM_ROOT" >&2
}

cmd_status() {
  if ! fm_linear_home_scoped "$FM_HOME" "$STATE"; then
    printf 'scope: inert (%s is not a firstmate primary home)\n' "$FM_HOME"
    return 0
  fi
  printf 'scope: primary home %s\n' "$FM_HOME"
  if ! fm_linear_present "$STATE"; then
    printf 'bindings: none (no Linear state in this home)\n'
    return 0
  fi
  printf 'bindings: %s task(s)\n' "$(fm_linear_bound_tasks "$STATE" | grep -c . || true)"
  printf 'pending: %s handback(s)\n' "$(fm_linear_pending_deliveries "$STATE" | grep -c . || true)"
  if fm_linear_config_load "$FM_HOME"; then
    printf 'credential: present at %s\n' "$(fm_linear_config_file "$FM_HOME")"
    printf 'endpoint: %s\n' "$FM_LINEAR_API_URL"
  else
    printf 'credential: unavailable - %s\n' "$FM_LINEAR_CONFIG_ERROR"
  fi
  printf 'transport: %s\n' "$(transport_path)"
}

# --- discard ----------------------------------------------------------------

cmd_discard() {
  local id=${1-} reason='' yes=0 file record
  shift || true
  [ -n "$id" ] || usage_die 'discard needs a delivery id'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -gt 1 ] || usage_die '--reason needs text'; reason=$2; shift 2 ;;
      --yes) yes=1; shift ;;
      *) usage_die "unknown discard option: $1" ;;
    esac
  done
  fm_linear_slug_valid "$id" || die "not a usable delivery id: $id"
  require_primary_home
  [ -n "$reason" ] || usage_die 'discard needs --reason "<why this handback is not owed>"'
  [ "$yes" -eq 1 ] || die 'discard drops an owed Linear handback; pass --yes to confirm'
  record=
  for file in \
    "$(fm_linear_outbox_dir "$STATE")/$id.json" \
    "$(fm_linear_refused_dir "$STATE")/$id.json"; do
    if [ -f "$file" ] && [ ! -L "$file" ]; then
      record=$file
      break
    fi
  done
  [ -n "$record" ] || die "no pending Linear delivery $id"
  {
    printf 'discarded_at=%s\n' "$(now_epoch)"
    printf 'task=%s\n' "$(fm_linear_record_field "$record" task_id)"
    printf 'issue=%s\n' "$(fm_linear_record_field "$record" issue)"
    printf 'reason=%s\n' "$(printf '%s' "$reason" | fm_linear_clean_line | fm_linear_bound_bytes 400)"
  } | fmx_private_artifact_publish_stdin "$(fm_linear_discarded_dir "$STATE")" "$id" 600 \
    || die 'cannot record the discard'
  rm -f -- "$record" "${record%.json}.reason" "$(fm_linear_attempts_dir "$STATE")/$id"
  printf 'discarded %s\n' "$id"
}

# --- delivery ---------------------------------------------------------------

transport_path() {
  if [ -n "${FM_LINEAR_TRANSPORT-}" ]; then
    printf '%s\n' "$FM_LINEAR_TRANSPORT"
  else
    printf '%s\n' "$SCRIPT_DIR/fm-linear-transport.sh"
  fi
}

# call_linear <query-file> <response-file>: run the configured transport and
# print its HTTP code. Returns non-zero when the exchange did not complete.
call_linear() {
  local request=$1 response=$2 transport code
  transport=$(transport_path)
  [ -f "$transport" ] && [ -x "$transport" ] \
    || { printf 'transport %s is not an executable file\n' "$transport" >&2; return 3; }
  code=$("$transport" "$request" "$response") || return $?
  printf '%s\n' "$code" | tr -d '[:space:]'
}

# graphql <response-file> <jq-filter>: read one value out of a GraphQL response.
graphql() {
  jq -r "$2" < "$1" 2>/dev/null
}

graphql_error() {  # <response-file>
  jq -r 'if (.errors // empty) then (.errors[0].message // "unspecified GraphQL error") else empty end' \
    < "$1" 2>/dev/null | fm_linear_clean_line | fm_linear_bound_bytes 300
}

build_request() {  # <out-file> <query> <variables-json>
  jq -n --arg q "$2" --argjson v "$3" '{query:$q, variables:$v}' > "$1"
}

hold_delivery() {  # <delivery-id> <reason>
  local id=$1 reason=$2 now
  now=$(now_epoch)
  {
    printf 'last_attempt=%s\n' "$now"
    printf 'next_attempt=%s\n' "$((now + FM_LINEAR_RETRY_BACKOFF_SECS))"
    printf 'reason=%s\n' "$(printf '%s' "$reason" | fm_linear_clean_line | fm_linear_bound_bytes 300)"
  } | fmx_private_artifact_publish_stdin "$(fm_linear_attempts_dir "$STATE")" "$id" 600 || true
}

refuse_delivery() {  # <delivery-id> <reason>
  local id=$1 reason=$2 outbox refused_dir clean_reason
  outbox="$(fm_linear_outbox_dir "$STATE")/$id.json"
  refused_dir=$(fm_linear_refused_dir "$STATE")
  clean_reason=$(printf '%s' "$reason" | fm_linear_clean_line | fm_linear_bound_bytes 300)
  if [ -f "$outbox" ] && [ ! -L "$outbox" ]; then
    if fmx_private_artifact_publish_stdin "$refused_dir" "$id.json" 600 < "$outbox" \
      && fmx_private_artifact_file_valid "$refused_dir" "$id.json" 600 \
      && printf '%s\n' "$clean_reason" | fmx_private_artifact_publish_stdin "$refused_dir" "$id.reason" 600 \
      && fmx_private_artifact_file_valid "$refused_dir" "$id.reason" 600; then
      rm -f -- "$outbox" "$(fm_linear_attempts_dir "$STATE")/$id"
      return 0
    fi
    rm -f -- "$refused_dir/$id.json" "$refused_dir/$id.reason"
    hold_delivery "$id" "$reason"
    return 1
  fi
  printf '%s\n' "$clean_reason" | fmx_private_artifact_publish_stdin "$refused_dir" "$id.reason" 600 || true
  rm -f -- "$(fm_linear_attempts_dir "$STATE")/$id"
  return 0
}

# GraphQL variable sigils, not shell expansions.
# shellcheck disable=SC2016
LINEAR_ISSUE_QUERY='query FmLinearIssue($id: String!, $first: Int!, $after: String) {
  issue(id: $id) {
    id
    identifier
    state { id name }
    team { id }
    comments(first: $first, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { id body }
    }
  }
}'

# GraphQL variable sigils, not shell expansions.
# shellcheck disable=SC2016
LINEAR_STATES_QUERY='query FmLinearStates($teamId: String!) {
  team(id: $teamId) { states(first: 100) { nodes { id name } } }
}'

# GraphQL variable sigils, not shell expansions.
# shellcheck disable=SC2016
LINEAR_COMMENT_MUTATION='mutation FmLinearComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) { success comment { id } }
}'

# GraphQL variable sigils, not shell expansions.
# shellcheck disable=SC2016
LINEAR_STATUS_MUTATION='mutation FmLinearStatus($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { id state { id name } } }
}'

# Resolved by read_back_issue for the current delivery.
ISSUE_UUID=
ISSUE_TEAM=
ISSUE_STATE_NAME=
FOUND_COMMENT_ID=

# read_back_issue <issue-ref> <marker>: walk the issue's comments looking for
# <marker>. Sets ISSUE_UUID/ISSUE_TEAM/ISSUE_STATE_NAME from the first page and
# FOUND_COMMENT_ID when the marker is already on the issue. Returns:
#   0 read-back completed (FOUND_COMMENT_ID tells you the answer)
#   1 the issue does not exist (permanent)
#   3 the read-back could not complete or was truncated (hold)
read_back_issue() {
  local issue=$1 marker=$2 request response after=null page=0 code err hit next
  ISSUE_UUID=; ISSUE_TEAM=; ISSUE_STATE_NAME=; FOUND_COMMENT_ID=
  request=$(new_tmp) || return 3
  response=$(new_tmp) || return 3
  while [ "$page" -lt "$FM_LINEAR_COMMENT_PAGE_MAX" ]; do
    page=$((page + 1))
    build_request "$request" "$LINEAR_ISSUE_QUERY" \
      "$(jq -n --arg id "$issue" --argjson first "$FM_LINEAR_COMMENT_PAGE_SIZE" --argjson after "$after" \
        '{id:$id, first:$first, after:$after}')" || return 3
    code=$(call_linear "$request" "$response") || return 3
    [ "$code" = 200 ] || { printf 'Linear returned HTTP %s\n' "$code" >&2; return 3; }
    err=$(graphql_error "$response")
    if [ -n "$err" ]; then
      case "$err" in
        *[Nn]ot\ found*|*does\ not\ exist*|*Entity\ not\ found*)
          printf '%s\n' "$err" >&2
          return 1
          ;;
      esac
      printf '%s\n' "$err" >&2
      return 3
    fi
    if [ "$(graphql "$response" '.data.issue // "null"')" = null ]; then
      printf 'issue %s does not exist or is not visible to this credential\n' "$issue" >&2
      return 1
    fi
    if [ -z "$ISSUE_UUID" ]; then
      ISSUE_UUID=$(graphql "$response" '.data.issue.id // ""')
      ISSUE_TEAM=$(graphql "$response" '.data.issue.team.id // ""')
      ISSUE_STATE_NAME=$(graphql "$response" '.data.issue.state.name // ""')
      [ -n "$ISSUE_UUID" ] || { printf 'Linear returned an issue with no id\n' >&2; return 3; }
    fi
    hit=$(jq -r --arg m "$marker" \
      '[.data.issue.comments.nodes[]? | select((.body // "") | contains($m)) | .id] | first // ""' \
      < "$response" 2>/dev/null)
    if [ -n "$hit" ]; then
      FOUND_COMMENT_ID=$hit
      return 0
    fi
    if [ "$(graphql "$response" '.data.issue.comments.pageInfo.hasNextPage // false')" != true ]; then
      return 0
    fi
    next=$(graphql "$response" '.data.issue.comments.pageInfo.endCursor // ""')
    [ -n "$next" ] || return 0
    after=$(jq -n --arg c "$next" '$c')
  done
  printf 'the issue has more comments than the %s-page read-back bound\n' "$FM_LINEAR_COMMENT_PAGE_MAX" >&2
  return 3
}

# deliver_one serializes on a per-delivery lock directory. Two concurrent runs
# would otherwise both complete a read-back before either posted, and both would
# then see a proven absence and post - the one duplicate the read-back cannot
# prevent on its own. An abandoned lock is taken over after
# FM_LINEAR_LOCK_STALE_SECS, because a crashed delivery must stay retryable.
deliver_one() {  # <delivery-id>
  local id=$1 lockdir rc age
  lockdir="$(fm_linear_root "$STATE")/.lock.$id"
  if ! mkdir "$lockdir" 2>/dev/null; then
    age=$(lock_age_secs "$lockdir")
    if [ -n "$age" ] && [ "$age" -ge "$FM_LINEAR_LOCK_STALE_SECS" ]; then
      rmdir "$lockdir" 2>/dev/null || true
    fi
    if ! mkdir "$lockdir" 2>/dev/null; then
      printf 'fm-linear-sync: another delivery of %s is already in progress; it is still owed\n' "$id" >&2
      return 3
    fi
  fi
  deliver_one_locked "$id"
  rc=$?
  rmdir "$lockdir" 2>/dev/null || true
  return "$rc"
}

lock_age_secs() {  # <path>
  local mtime now
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$1" 2>/dev/null) || return 0
  else
    mtime=$(stat -c %Y "$1" 2>/dev/null) || return 0
  fi
  [ -n "$mtime" ] || return 0
  now=$(now_epoch)
  printf '%s\n' "$((now - mtime))"
}

deliver_one_locked() {  # <delivery-id>
  local id=$1 record task issue status comment marker body request response
  local rc code err comment_id proof state_id
  record="$(fm_linear_outbox_dir "$STATE")/$id.json"
  if fmx_private_artifact_file_valid "$(fm_linear_sent_dir "$STATE")" "$id" 600; then
    rm -f -- "$record" "$(fm_linear_attempts_dir "$STATE")/$id"
    printf 'already delivered: %s\n' "$id"
    return 0
  fi
  if [ ! -f "$record" ] || [ -L "$record" ]; then
    if fmx_private_artifact_file_valid "$(fm_linear_refused_dir "$STATE")" "$id.json" 600; then
      printf 'fm-linear-sync: delivery %s was refused by Linear; inspect it with the show command, then re-queue or discard it\n' "$id" >&2
      return 1
    fi
    printf 'fm-linear-sync: no pending Linear delivery %s\n' "$id" >&2
    return 1
  fi

  task=$(jq -r '.task_id // ""' < "$record")
  issue=$(jq -r '.issue // ""' < "$record")
  status=$(jq -r '.status // ""' < "$record")
  marker=$(jq -r '.marker // ""' < "$record")
  comment=$(new_tmp) || return 3
  jq -j '.comment // ""' < "$record" > "$comment" || return 3

  # The record must still hash to its own filename, and the issue must still be
  # bound to the task. A tampered or orphaned record never reaches Linear.
  if [ "$(fm_linear_delivery_id "$task" "$issue" "$status" "$comment")" != "$id" ]; then
    if refuse_delivery "$id" 'the delivery record does not match its own derived identity'; then
      printf 'fm-linear-sync: delivery %s failed its identity check and was quarantined\n' "$id" >&2
      return 1
    fi
    printf 'fm-linear-sync: delivery %s failed its identity check but could not be quarantined; it is preserved and still owed\n' "$id" >&2
    return 3
  fi
  if [ "$marker" != "$(fm_linear_marker "$id")" ]; then
    if refuse_delivery "$id" 'the delivery record carries a marker that is not its own'; then
      printf 'fm-linear-sync: delivery %s carries a forged marker and was quarantined\n' "$id" >&2
      return 1
    fi
    printf 'fm-linear-sync: delivery %s carries a forged marker but could not be quarantined; it is preserved and still owed\n' "$id" >&2
    return 3
  fi
  if ! fm_linear_binding_issues "$STATE" "$task" | grep -Fxq -- "$issue"; then
    hold_delivery "$id" "issue $issue is no longer bound to task $task"
    printf 'fm-linear-sync: issue %s is no longer bound to task %s; re-bind it or discard delivery %s\n' \
      "$issue" "$task" "$id" >&2
    return 3
  fi

  if ! fm_linear_config_load "$FM_HOME"; then
    hold_delivery "$id" "$FM_LINEAR_CONFIG_ERROR"
    printf 'fm-linear-sync: Linear is not connected (%s); handback for task %s on %s is preserved and still owed\n' \
      "$FM_LINEAR_CONFIG_ERROR" "$task" "$issue" >&2
    return 3
  fi

  read_back_issue "$issue" "$marker"
  rc=$?
  case "$rc" in
    0) ;;
    1)
      if refuse_delivery "$id" "issue $issue is not reachable on this Linear workspace"; then
        printf 'fm-linear-sync: Linear does not have issue %s; delivery %s is held for a decision\n' "$issue" "$id" >&2
        return 1
      fi
      printf 'fm-linear-sync: Linear does not have issue %s and delivery %s could not be quarantined; it is preserved and still owed\n' "$issue" "$id" >&2
      return 3
      ;;
    *)
      hold_delivery "$id" 'the issue read-back did not complete'
      printf 'fm-linear-sync: could not confirm the current state of %s; handback for task %s is preserved and still owed\n' \
        "$issue" "$task" >&2
      return 3
      ;;
  esac

  if [ -n "$FOUND_COMMENT_ID" ]; then
    comment_id=$FOUND_COMMENT_ID
    proof=read-back
  else
    body=$(new_tmp) || return 3
    { cat "$comment"; fm_linear_comment_body_suffix "$id"; } > "$body"
    request=$(new_tmp) || return 3
    response=$(new_tmp) || return 3
    build_request "$request" "$LINEAR_COMMENT_MUTATION" \
      "$(jq -n --arg issueId "$ISSUE_UUID" --rawfile body "$body" '{issueId:$issueId, body:$body}')" \
      || return 3
    code=$(call_linear "$request" "$response") || {
      hold_delivery "$id" 'the comment request did not complete'
      printf 'fm-linear-sync: could not reach Linear to post the handback for task %s on %s; it is preserved and still owed\n' \
        "$task" "$issue" >&2
      return 3
    }
    if [ "$code" != 200 ]; then
      hold_delivery "$id" "Linear returned HTTP $code on comment create"
      printf 'fm-linear-sync: Linear returned HTTP %s posting the handback for task %s on %s; it is preserved and still owed\n' \
        "$code" "$task" "$issue" >&2
      return 3
    fi
    err=$(graphql_error "$response")
    if [ -n "$err" ]; then
      hold_delivery "$id" "$err"
      printf 'fm-linear-sync: Linear rejected the handback for task %s on %s (%s); it is preserved and still owed\n' \
        "$task" "$issue" "$err" >&2
      return 3
    fi
    if [ "$(graphql "$response" '.data.commentCreate.success // false')" != true ]; then
      hold_delivery "$id" 'Linear reported the comment was not created'
      printf 'fm-linear-sync: Linear did not accept the handback for task %s on %s; it is preserved and still owed\n' \
        "$task" "$issue" >&2
      return 3
    fi
    comment_id=$(graphql "$response" '.data.commentCreate.comment.id // ""')
    proof=posted
  fi

  local status_applied=0
  if [ -n "$status" ]; then
    if [ "$ISSUE_STATE_NAME" = "$status" ]; then
      status_applied=1
    else
      request=$(new_tmp) || return 3
      response=$(new_tmp) || return 3
      build_request "$request" "$LINEAR_STATES_QUERY" \
        "$(jq -n --arg teamId "$ISSUE_TEAM" '{teamId:$teamId}')" || return 3
      code=$(call_linear "$request" "$response") || {
        hold_delivery "$id" 'the workflow-state lookup did not complete'
        printf 'fm-linear-sync: the handback comment for task %s landed on %s, but its status change is still owed\n' \
          "$task" "$issue" >&2
        return 3
      }
      state_id=$(jq -r --arg n "$status" \
        '[.data.team.states.nodes[]? | select(.name == $n) | .id] | first // ""' \
        < "$response" 2>/dev/null)
      if [ -z "$state_id" ]; then
        if refuse_delivery "$id" "the team has no workflow state named '$status'"; then
          printf 'fm-linear-sync: %s has no workflow state named "%s"; delivery %s is held for a decision\n' \
            "$issue" "$status" "$id" >&2
          return 1
        fi
        printf 'fm-linear-sync: %s has no workflow state named "%s" and delivery %s could not be quarantined; it is preserved and still owed\n' \
          "$issue" "$status" "$id" >&2
        return 3
      fi
      build_request "$request" "$LINEAR_STATUS_MUTATION" \
        "$(jq -n --arg id "$ISSUE_UUID" --arg stateId "$state_id" '{id:$id, stateId:$stateId}')" || return 3
      code=$(call_linear "$request" "$response") || code=
      if [ "$code" = 200 ] \
        && [ "$(graphql "$response" '.data.issueUpdate.success // false')" = true ] \
        && [ "$(graphql "$response" '.data.issueUpdate.issue.state.name // ""')" = "$status" ]; then
        status_applied=1
      else
        hold_delivery "$id" "the status change to '$status' was not confirmed"
        printf 'fm-linear-sync: the handback comment for task %s landed on %s, but its status change to "%s" is still owed\n' \
          "$task" "$issue" "$status" >&2
        return 3
      fi
    fi
  fi

  {
    printf 'delivered_at=%s\n' "$(now_epoch)"
    printf 'task=%s\n' "$task"
    printf 'issue=%s\n' "$issue"
    printf 'issue_id=%s\n' "$ISSUE_UUID"
    printf 'comment_id=%s\n' "$comment_id"
    printf 'marker=%s\n' "$marker"
    printf 'status=%s\n' "$status"
    printf 'status_applied=%s\n' "$status_applied"
    printf 'proof=%s\n' "$proof"
  } | fmx_private_artifact_publish_stdin_once "$(fm_linear_sent_dir "$STATE")" "$id" 600
  case $? in
    0|1) ;;
    *)
      hold_delivery "$id" 'the handback landed but its receipt could not be recorded'
      printf 'fm-linear-sync: the handback for task %s landed on %s but its receipt could not be written\n' \
        "$task" "$issue" >&2
      return 3
      ;;
  esac
  rm -f -- "$record" "$(fm_linear_attempts_dir "$STATE")/$id"
  printf 'delivered %s -> %s (%s, %s)\n' "$task" "$issue" "$id" "$proof"
}

cmd_deliver() {
  local target='' task='' all=0 id rc worst=0 any=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -gt 1 ] || usage_die '--task needs a task id'; task=$2; shift 2 ;;
      --all) all=1; shift ;;
      -*) usage_die "unknown deliver option: $1" ;;
      *) [ -z "$target" ] || usage_die 'deliver takes one delivery id'; target=$1; shift ;;
    esac
  done
  require_primary_home
  require_jq
  if [ -n "$target" ]; then
    [ "$all" -eq 0 ] && [ -z "$task" ] || usage_die 'deliver takes a delivery id OR --task OR --all'
    fm_linear_slug_valid "$target" || die "not a usable delivery id: $target"
    deliver_one "$target"
    return $?
  fi
  [ "$all" -eq 1 ] || [ -n "$task" ] || usage_die 'deliver needs a delivery id, --task <id>, or --all'
  [ -z "$task" ] || fm_linear_slug_valid "$task" || die "not a usable task id: $task"
  fm_linear_present "$STATE" || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # A refused delivery is reported by `pending`, never retried by a sweep.
    [ -f "$(fm_linear_outbox_dir "$STATE")/$id.json" ] || continue
    any=1
    deliver_one "$id"
    rc=$?
    [ "$rc" -le "$worst" ] || worst=$rc
  done < <(fm_linear_pending_deliveries "$STATE" "$task")
  [ "$any" -eq 1 ] || printf 'no queued Linear handbacks\n'
  return "$worst"
}

# --- dispatch ---------------------------------------------------------------

VERB=${1-}
shift || true
case "$VERB" in
  bind)       cmd_bind "$@" ;;
  unbind)     cmd_unbind "$@" ;;
  bindings)   cmd_bindings "$@" ;;
  queue)      cmd_queue "$@" ;;
  pending)    cmd_pending "$@" ;;
  show)       cmd_show "$@" ;;
  deliver)    cmd_deliver "$@" ;;
  guard-work) cmd_guard_work "$@" ;;
  discard)    cmd_discard "$@" ;;
  hook)       cmd_hook "$@" ;;
  status)     cmd_status "$@" ;;
  -h|--help)  usage; exit 0 ;;
  '')         usage; exit 2 ;;
  *)          usage_die "unknown command: $VERB" ;;
esac
