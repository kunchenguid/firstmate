#!/usr/bin/env bash
# Run one isolated repair round from a surviving PR context and monitor event.
# Usage: fm-pr-fix-seat.sh <context-task> [--project <existing-clone>] -- <routing-args>
#        fm-pr-fix-seat.sh observe <context-task> < monitor-snapshot.json
#        fm-pr-fix-seat.sh prepare <context-task> <repair-task>
#        fm-pr-fix-seat.sh reply <context-task> <repair-task> <thread-id> < reply.md
#        fm-pr-fix-seat.sh finish <context-task> <repair-task> < context.json
#        fm-pr-fix-seat.sh defer <context-task> <repair-task> < reason.txt
#        fm-pr-fix-seat.sh ready <repair-task> <PR-URL> <head> <copy>
#        fm-pr-fix-seat.sh retirement-stage <repair-task> [--cancel]
#        fm-pr-fix-seat.sh retired <repair-task>
#        fm-pr-fix-seat.sh archive <context-task>
#        fm-pr-fix-seat.sh reconcile
#        fm-pr-fix-seat.sh --help
# Routing arguments are the concrete fm-spawn.sh axes and dispatch attestation;
# this helper never interprets natural-language profiles or invents an attestation.
# An omitted project selects the owning home or its projects/<repository> clone
# only when its canonical origin is the context's exact head repository.
# The durable state/pr-fix-seat-<PR-number>.json reservation precedes spawn and
# survives launcher failure. Its short mutation lock is not held across launch.
# Duplicate intake records pending evidence, never launches another worker.
# observe is the monitor's pre-commit hook: retain new generations even during
# debounce or launch, and refuse before the monitor advances if storage fails.
# prepare runs inside the allocated worktree and creates fm/<repair-task> at
# the exact observed PR head. It refuses dirty or primary copies and never
# resets a branch or mutates the remote. Retrying a prepared round is harmless.
# reply uses the publication gate, binds the thread to this round, and stores
# returned comment/review identities. An ambiguous publication is never retried
# automatically; confirmed identical replies converge without another request.
# finish validates exact-head evidence and immutable context bindings before a
# normal single-ref push (no tags/submodules/default branch). Publication intent
# survives failures; retries require identical input and never repush an observed
# delivered head. Pending/failed CI retains the reservation, not a done signal.
# Successful completion rewrites the original context and records done once.
# defer records a nonempty reason without fabricating evidence for a new head;
# its escalation blocks new rounds until the owner reconciles the reservation.
# Dirty or unpublished work still refuses ordinary teardown.
# ready prints the completed/deferred/retiring phase without bypassing teardown
# guards. A retiring receipt binds the preserved debrief for copy-free retries.
# Explicit operator discard passes --cancel, preserves a cancellation receipt,
# and blocks automatic retry; it never authorizes cleanup itself.
# Teardown calls retirement-stage after physical cleanup but before
# metadata removal, then retired afterwards. reconcile recovers missed callbacks.
# Pending identities survive context rewrites and exclude confirmed own replies.
# Retirement wakes are durable at-least-once: a crash after queue publication can
# repeat a wake, but reservation/generation checks prevent duplicate workers.
# archive requires acknowledged terminal monitor evidence and no active repair.
# data/<task>/pr-archive.json quarantines writes/installation during the move.
# Its schema-1 manifest binds task, URL, archive-directory basename, and SHA256s
# of context, snapshot and journal. Verified copies precede source removals;
# retries resume that manifest even when a source is gone. Completed manifests
# live with pr-context.md, snapshot.json and pr-repair.json in the private
# data/<task>/pr-archive.XXXXXX directory. No historical archive is overwritten.
# An archived reservation retains its round counter, permitting a new context
# without reusing a previous repair task identity. reconcile scans contexts and
# unfinished manifests even when the original task metadata no longer exists.
# Context and feedback are inert data. No command from either is evaluated here.
# FM_HOME, FM_STATE_OVERRIDE and FM_DATA_OVERRIDE select the owning stores.
# FM_PR_FIX_SPAWN_BIN replaces only the spawn side effect in portable tests.
set -eu
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LOCK='' PUBLISH_LOCK='' CONTEXT_LOCK='' TMP_FILE='' WORK_DIR=''
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-comment-watch-lib.sh
. "$SCRIPT_DIR/fm-pr-comment-watch-lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
die() { printf 'error: PR repair: %s\n' "$*" >&2; exit 1; }
cleanup() {
  [ -z "$WORK_DIR" ] || rm -rf -- "$WORK_DIR"
  [ -z "$TMP_FILE" ] || rm -f -- "$TMP_FILE"
  [ -z "$LOCK" ] || fm_lock_release "$LOCK"
  [ -z "$PUBLISH_LOCK" ] || fm_lock_release "$PUBLISH_LOCK"
  [ -z "$CONTEXT_LOCK" ] || fm_lock_release "$CONTEXT_LOCK"
  fm_pr_meta_cleanup
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

atomic() { # <file> <json> [owning-store]
  local store=${3:-$STATE}
  fm_pr_regular_destination_on_device_or_absent "$1" "$(fm_pr_file_device "$store")" || die 'unsafe state destination'
  TMP_FILE=$(mktemp "$store/.pr-fix-seat.XXXXXX") || die 'cannot stage repair state'
  printf '%s\n' "$2" > "$TMP_FILE"
  chmod 600 "$TMP_FILE"
  mv -f -- "$TMP_FILE" "$1"
  TMP_FILE=
}

load_context() {
  fm_pr_task_id_valid "$TASK" || die 'unsafe context task'
  fm_pcw_state_prepare "$STATE" "$FM_HOME" || die 'unsafe owning state directory'
  CONTEXT_HASH=$(fm_pr_sha256 "$DATA/$TASK/pr-context.md")
  CTX=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-pr-context.sh" validate "$TASK" --json) \
    || die 'invalid context'
  [ "$CONTEXT_HASH" = "$(fm_pr_sha256 "$DATA/$TASK/pr-context.md")" ] || die 'context changed during validation'
  FM_HOME=$(CDPATH='' cd -- "$FM_HOME" && pwd -P)
  STATE=$(CDPATH='' cd -- "$STATE" && pwd -P)
  DATA=$(CDPATH='' cd -- "$DATA" && pwd -P)
  URL=$(printf '%s' "$CTX" | jq -r .pr_url)
  REPO=$(printf '%s' "$CTX" | jq -r .repo)
  fm_pr_url_parse "$URL" || die 'invalid PR identity'
  NUMBER=$FM_PR_NUMBER
  JOURNAL_PATH="$STATE/pr-fix-seat-$NUMBER.json"
}

lock_state() {
  fm_pr_meta_lock_helpers
  LOCK="$STATE/.pr-fix-seat-$NUMBER.lock"
  fm_lock_try_acquire "$LOCK" || { LOCK=; die 'repair state is busy; retry the same intake'; }
  JOURNAL=$(jq -cn --arg task "$TASK" --arg url "$URL" \
    '{schema:1,task:$task,url:$url,round:0,last_generation:0,active:null,pending:[]}')
  if [ -e "$JOURNAL_PATH" ] || [ -L "$JOURNAL_PATH" ]; then
    fm_pr_private_file_valid "$JOURNAL_PATH" 600 "$(fm_pr_file_device "$STATE")" || die 'unsafe repair state'
    JOURNAL=$(jq -e --arg task "$TASK" --arg url "$URL" '
      select(.schema==1 and ((.task==$task and .url==$url) or (.archived==true and .active==null)) and
        (.round|type=="number" and .>=0 and .<2147483647 and .==floor) and
        (.last_generation|type=="number" and .>=0 and .<2147483647 and .==floor) and
        (.pending|type=="array" and length<=128) and
        (.active==null or (.active.id|type=="string" and test("^pr-repair-[1-9][0-9]*-[1-9][0-9]*$"))))
    ' "$JOURNAL_PATH") || die 'invalid or differently owned repair state'
    if [ "$(printf '%s' "$JOURNAL" | jq '.archived==true and .active==null')" = true ]; then
      JOURNAL=$(printf '%s' "$JOURNAL" | jq --arg task "$TASK" --arg url "$URL" \
        '{schema:1,task:$task,url:$url,round:.round,last_generation:0,active:null,pending:[]}')
    fi
  fi
}
unlock_state() { fm_lock_release "$LOCK" || die 'cannot release repair state lock'; LOCK=; }

# ponytail: 128 observed batches per round; segment the journal if long-lived
# repairs need more. Refuse before advancing the monitor, never evict evidence.
record_pending() { # requires the mutation lock and SNAPSHOT
  [ "$(printf '%s' "$JOURNAL" | jq -r '.active != null')" = true ] || return 0
  JOURNAL=$(printf '%s' "$JOURNAL" | jq --argjson snapshot "$SNAPSHOT" '
    ([.active.snapshot.generation] + [.pending[].generation] | max) as $last |
    if $snapshot.generation <= $last then .
    elif (.pending|length)>=128 then error("pending repair capacity exceeded")
    else .pending += [$snapshot + {observed_after_delivery:(.active.delivery.context!=null)}] end') || die 'cannot retain pending feedback'
  atomic "$JOURNAL_PATH" "$JOURNAL"
}

observe() {
  TASK=$1
  fm_pr_task_id_valid "$TASK" || die 'unsafe context task'
  SNAPSHOT=$(jq -se 'if length==1 and (.[0]|type)=="object" then .[0] else error("expected one snapshot") end') \
    || die 'invalid monitor snapshot'
  fm_pr_url_parse "$(printf '%s' "$SNAPSHOT" | jq -r .url)" || die 'invalid monitor PR identity'
  [ -e "$STATE/pr-fix-seat-$FM_PR_NUMBER.json" ] || [ -L "$STATE/pr-fix-seat-$FM_PR_NUMBER.json" ] || return 0
  load_context
  printf '%s' "$SNAPSHOT" | jq -e --arg task "$TASK" --arg url "$URL" \
    --arg hash "$(fm_pr_sha256 "$DATA/$TASK/pr-context.md")" '
      .schema==1 and .task==$task and .url==$url and .context_hash==$hash and
      (.generation|type=="number" and .>=0 and .<2147483647 and .==floor)
    ' >/dev/null || die 'monitor snapshot does not match the context'
  lock_state
  record_pending
}

project_matches() {
  local origin
  [ -d "$1" ] || return 1
  origin=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  fm_project_origin_is_canonical_github "$origin" "$REPO"
}

has_index() { [ -e "$STATE/$1.pr-repair.json" ] || [ -L "$STATE/$1.pr-repair.json" ]; }

repair_open() { # <repair-task> [retired]; holds the mutation lock, needs no copy
  local index
  SEAT=$1
  fm_pr_task_id_valid "$SEAT" || die 'unsafe repair task'
  fm_pcw_state_prepare "$STATE" "$FM_HOME" || die 'unsafe owning state directory'
  fm_pr_private_file_valid "$STATE/$SEAT.pr-repair.json" 600 "$(fm_pr_file_device "$STATE")" || die 'unsafe repair index'
  index=$(jq -e --arg id "$SEAT" 'select(.schema==1 and .id==$id)' "$STATE/$SEAT.pr-repair.json") \
    || die 'invalid repair index'
  TASK=$(printf '%s' "$index" | jq -r .task)
  load_context
  [ "$(printf '%s' "$index" | jq -r .url)" = "$URL" ] || die 'repair index PR changed'
  lock_state
  if [ "$(printf '%s' "$JOURNAL" | jq -r .active.id)" != "$SEAT" ]; then
    if [ "${2:-}" != retired ] || [ "$(printf '%s' "$JOURNAL" | jq -r .last_outcome.id)" != "$SEAT" ]; then
      die 'repair does not own this PR'
    fi
  fi
}

worker_open() { # <context-task> <repair-task>; holds the repair mutation lock
  local task=$1
  fm_pr_task_id_valid "$task" || die 'unsafe context task'
  repair_open "$2"
  [ "$TASK" = "$task" ] || die 'repair index does not match the requested context'
  [ -d "$DATA/$SEAT" ] && [ ! -L "$DATA/$SEAT" ] || die 'unsafe repair data directory'
  META="$STATE/$SEAT.meta"
  fm_pr_private_file_valid "$META" 600 "$(fm_pr_file_device "$STATE")" || die 'missing or unsafe repair metadata'
  [ "$(fm_backend_meta_exact_value "$META" kind)" = ship ] || die 'repair is not a writer'
  COPY=$(fm_backend_meta_exact_value "$META" worktree) || die 'ambiguous repair worktree'
  COPY=$(CDPATH='' cd -- "$COPY" && pwd -P) || die 'missing repair worktree'
  PROJECT=$(printf '%s' "$JOURNAL" | jq -er .active.project)
  [ "$(fm_backend_meta_exact_value "$META" project)" = "$PROJECT" ] || die 'repair project binding changed'
  BASE=$(printf '%s' "$JOURNAL" | jq -r .active.snapshot.observed.head)
  fm_pr_head_valid "$BASE" || die 'invalid repair base'
  BRANCH="fm/$SEAT"
}

validate_copy() {
  [ "$COPY" != "$PROJECT" ] && [ "$(git -C "$COPY" rev-parse --show-toplevel)" = "$COPY" ] \
    || die 'not an isolated repair worktree'
  [ "$(git -C "$COPY" rev-parse --absolute-git-dir)" != \
    "$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)" ] || die 'repair copy is the primary checkout'
  case "$FM_HOME/" in "$COPY/"*) die 'owning home would be removed with the repair' ;; esac
  case "$DATA/" in "$COPY/"*) die 'durable context would be removed with the repair' ;; esac
  project_matches "$COPY" || die 'repair copy origin changed'
}

prepare_worker() {
  local prepared
  worker_open "$1" "$2"
  case "$(printf '%s' "$JOURNAL" | jq -r .active.phase)" in active|launching) ;; *) die 'repair is not accepting work' ;; esac
  prepared=$(printf '%s' "$JOURNAL" | jq -r '.active.prepared // false')
  unlock_state
  validate_copy
  [ "$(git rev-parse --show-toplevel)" = "$COPY" ] || die 'run preparation inside the allocated repair copy'
  [ -z "$(git -C "$COPY" status --porcelain)" ] || die 'repair worktree has uncommitted changes'
  if [ "$prepared" = true ]; then
    if [ "$(git -C "$COPY" symbolic-ref --short HEAD)" != "$BRANCH" ] ||
        ! git -C "$COPY" merge-base --is-ancestor "$BASE" HEAD; then
      die 'prepared repair branch changed'
    fi
    return 0
  fi
  git -C "$COPY" fetch origin "refs/heads/$(printf '%s' "$CTX" | jq -r .branch)" || die 'cannot fetch the PR branch'
  [ "$(git -C "$COPY" rev-parse FETCH_HEAD)" = "$BASE" ] || die 'PR head moved after repair intake'
  git -C "$COPY" checkout -b "$BRANCH" "$BASE" || die 'cannot create the isolated repair branch'
  lock_state
  [ "$(printf '%s' "$JOURNAL" | jq -r .active.id)" = "$SEAT" ] || die 'repair ownership changed during preparation'
  atomic "$JOURNAL_PATH" "$(printf '%s' "$JOURNAL" | jq '.active.prepared=true')"
  printf 'prepared: %s %s\n' "$SEAT" "$URL"
}

probe_remote() {
  REMOTE=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-pr-context-watch.sh" probe "$TASK") || die 'cannot verify the current PR'
  printf '%s' "$REMOTE" | jq -e --argjson ctx "$CTX" '
    .state=="OPEN" and .url==$ctx.pr_url and .repo==$ctx.repo and .branch==$ctx.branch
  ' >/dev/null || die 'PR is no longer open with the recorded identity'
}

reply_worker() {
  local thread=$3 expected body_hash existing wire reply
  worker_open "$1" "$2"
  validate_copy
  [ "$(git rev-parse --show-toplevel)" = "$COPY" ] || die 'reply outside the allocated repair copy'
  printf '%s' "$JOURNAL" | jq -e '.active.prepared==true and (.active.phase=="active" or .active.phase=="launching")' \
    >/dev/null || die 'repair is not accepting replies'
  expected=$(printf '%s' "$JOURNAL" | jq -er --arg id "$thread" \
    '.active.snapshot.feedback.threads[] | select(.id==$id) | .comments.nodes[-1].id') || die 'thread was not assigned to this round'
  WORK_DIR=$(mktemp -d "$DATA/$SEAT/.pr-repair.XXXXXX") || die 'cannot stage reply'
  head -c 65537 > "$WORK_DIR/reply.md"
  if [ "$(wc -c < "$WORK_DIR/reply.md")" -gt 65536 ] || ! grep -q '[^[:space:]]' "$WORK_DIR/reply.md"; then
    die 'reply must be nonempty and at most 64 KiB'
  fi
  "$SCRIPT_DIR/fm-pr-body.sh" check --file "$WORK_DIR/reply.md" || die 'reply failed the publication gate'
  body_hash=$(fm_pr_sha256 "$WORK_DIR/reply.md")
  existing=$(printf '%s' "$JOURNAL" | jq -c --arg id "$thread" '.active.replies[$id] // null')
  if [ "$existing" != null ]; then
    printf '%s' "$existing" | jq -e --arg hash "$body_hash" '.body_hash==$hash and .phase=="confirmed"' >/dev/null \
      || die 'reply is different or its earlier publication is unresolved; investigate before retrying'
    printf '%s\n' "$existing"
    return 0
  fi
  unlock_state
  probe_remote
  [ "$(printf '%s' "$REMOTE" | jq -r .head)" = "$BASE" ] || die 'PR head moved before reply'
  [ "$(printf '%s' "$REMOTE" | jq -er --arg id "$thread" '.threads[] | select(.id==$id) | .comments.nodes[-1].id')" = "$expected" ] \
    || die 'thread changed during this round; do not reply over unhandled feedback'
  lock_state
  [ "$(printf '%s' "$JOURNAL" | jq -r .active.id)" = "$SEAT" ] || die 'repair ownership changed before reply'
  printf '%s' "$JOURNAL" | jq -e --arg id "$thread" '.active.replies[$id]==null' >/dev/null || die 'reply is already in progress'
  atomic "$JOURNAL_PATH" "$(printf '%s' "$JOURNAL" | jq --arg id "$thread" --arg hash "$body_hash" \
    '.active.replies[$id]={phase:"unresolved",body_hash:$hash}')"
  unlock_state
  # Persist the intent before the request; a lost response must not double-post.
  # shellcheck disable=SC2016 # These dollar identifiers belong to GraphQL, not the shell.
  wire=$(GH_HOST=github.com "$SCRIPT_DIR/fm-pr-body.sh" publish --file "$WORK_DIR/reply.md" -- \
    "${FM_PR_CONTEXT_GH_CMD:-gh-axi}" api POST graphql \
    --field 'query=mutation($thread:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$thread,body:$body}){comment{id url pullRequest{url} pullRequestReview{id}}}}' \
    --field "thread=$thread" --field "body=$(cat "$WORK_DIR/reply.md")" --jq '
      if (.errors//[]|length)>0 then error("reply failed") else
        {reply:(.data.addPullRequestReviewThreadReply.comment|tojson)} end') \
    || die 'reply outcome unresolved; do not retry the publication'
  reply=$(printf '%s\n' "$wire" | jq -Rse --arg url "$URL" --arg hash "$body_hash" '
    split("\n") | map(select(length>0)) |
    if length==1 then .[0] else error("unexpected reply rows") end |
    capture("^reply: (?<json>\".*\")$").json | fromjson | fromjson |
    if (.id|type=="string" and length>0) and .pullRequest.url==$url and
      (.url|type=="string" and startswith($url+"#")) and
      (.pullRequestReview.id==null or (.pullRequestReview.id|type=="string" and length>0))
    then {phase:"confirmed",body_hash:$hash,id,url,review_id:.pullRequestReview.id}
    else error("mismatched reply") end') || die 'reply response unresolved; inspect the recorded PR before retrying'
  lock_state
  [ "$(printf '%s' "$JOURNAL" | jq -r .active.id)" = "$SEAT" ] || die 'repair ownership changed after publication'
  atomic "$JOURNAL_PATH" "$(printf '%s' "$JOURNAL" | jq --arg id "$thread" --argjson reply "$reply" '.active.replies[$id]=$reply')"
  printf '%s\n' "$reply"
}

repair_meta_matches() { [ "$FM_PR_META_URL" = "$URL" ]; }

finish_status() { # Requires the repair mutation lock and a terminal receipt.
  local line=${1:-"done: PR $URL checks green"} status="$STATE/$SEAT.status"
  if [ ! -e "$status" ] && [ ! -L "$status" ]; then
    (umask 077; set -C; : > "$status") 2>/dev/null || : # Never clobber a concurrent creator.
  fi
  fm_pr_private_file_valid "$status" 600 "$(fm_pr_file_device "$STATE")" || die 'unsafe repair status'
  if ! grep -Fxq "$line" "$status"; then printf '%s\n' "$line" >> "$status"; fi
  printf 'completed: %s %s\n' "$SEAT" "$URL"
}

require_debrief() {
  local debrief="$COPY/data/$SEAT/debrief.md"
  [ ! -L "$COPY/data" ] && [ ! -L "$COPY/data/$SEAT" ] &&
    [ -f "$debrief" ] && [ ! -L "$debrief" ] && [ -s "$debrief" ] || die 'repair debrief is missing or unsafe'
}

finish_worker() {
  local candidate head destination phase prior delivered push_url context_hash
  worker_open "$1" "$2"
  PUBLISH_LOCK="$STATE/.pr-repair-$SEAT.publish.lock"
  fm_lock_try_acquire "$PUBLISH_LOCK" || { PUBLISH_LOCK=; die 'publication is busy; retry identical input later'; }
  unlock_state
  validate_copy
  [ "$(git rev-parse --show-toplevel)" = "$COPY" ] || die 'finish outside the allocated repair copy'
  [ "$(git -C "$COPY" symbolic-ref --short HEAD)" = "$BRANCH" ] || die 'repair branch changed'
  [ -z "$(git -C "$COPY" status --porcelain)" ] || die 'repair has uncommitted changes'
  head=$(git -C "$COPY" rev-parse HEAD)
  git -C "$COPY" merge-base --is-ancestor "$BASE" "$head" || die 'repair does not descend from its observed head'
  require_debrief
  WORK_DIR=$(mktemp -d "$DATA/$SEAT/.pr-repair.XXXXXX") || die 'cannot stage completion'
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$WORK_DIR/context" "$SCRIPT_DIR/fm-pr-context.sh" write "$TASK" >/dev/null \
    || die 'invalid completion context'
  candidate=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$WORK_DIR/context" \
    "$SCRIPT_DIR/fm-pr-context.sh" validate "$TASK" --json) || die 'invalid completion context'
  CTX=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-pr-context.sh" validate "$TASK" --json) \
    || die 'current context is unavailable'
  lock_state
  [ "$(printf '%s' "$JOURNAL" | jq -r .active.id)" = "$SEAT" ] || die 'repair ownership changed during validation'
  printf '%s' "$JOURNAL" | jq -e --argjson candidate "$candidate" --arg head "$head" --argjson ctx "$CTX" '
    .active.context as $original |
    .active.prepared==true and $candidate.head==$head and
    all(["pr_url","repo","branch","oracle","pre_push_command","merge_authority"][];
      . as $key | $candidate[$key]==$original[$key]) and
    ($ctx==$original or $ctx==.active.delivery.context) and
    (.active.delivery==null or .active.delivery.input==$candidate)
  ' >/dev/null || die 'completion changed evidence identity, oracle, merge authority, or an earlier publication input'
  phase=$(printf '%s' "$JOURNAL" | jq -r .active.phase)
  case "$phase" in
    completed) finish_status; return 0 ;;
    active|launching|publishing) ;;
    *) die 'repair is not accepting completion' ;;
  esac
  destination=$(printf '%s' "$candidate" | jq -r .branch)
  push_url=$(git -C "$COPY" remote get-url --push --all origin) || die 'cannot resolve publication remote'
  fm_project_origin_is_canonical_github "$push_url" "$REPO" || die 'publication remote is not the recorded repository'
  unlock_state
  probe_remote
  printf '%s' "$REMOTE" | jq -e --arg branch "$destination" '
    (.default_branch|type=="string" and length>0) and .default_branch!=$branch
  ' >/dev/null || die 'publication would target the default branch or its identity is unavailable'
  prior=$(printf '%s' "$REMOTE" | jq -r .head)
  [ "$prior" = "$BASE" ] || [ "$prior" = "$head" ] || die 'PR head moved outside this repair'
  # Every assigned unresolved thread needs a confirmed reply or a current resolution.
  printf '%s' "$JOURNAL" | jq -e --argjson remote "$REMOTE" '
    .active as $active | all($active.snapshot.feedback.threads[] | select(.isResolved|not);
      .id as $id | $active.replies[$id].phase=="confirmed" or
        any($remote.threads[]; .id==$id and .isResolved))
  ' >/dev/null || die 'an assigned thread has neither a confirmed reply nor a current resolution'
  lock_state
  [ "$(printf '%s' "$JOURNAL" | jq -r .active.id)" = "$SEAT" ] || die 'repair ownership changed before publication'
  if [ "$(printf '%s' "$JOURNAL" | jq '.active.delivery==null')" = true ]; then
    JOURNAL=$(printf '%s' "$JOURNAL" | jq --argjson input "$candidate" \
      '.active.phase="publishing" | .active.delivery={input:$input}')
    atomic "$JOURNAL_PATH" "$JOURNAL"
  fi
  unlock_state
  if [ "$prior" != "$head" ]; then
    git -C "$COPY" push --no-follow-tags --recurse-submodules=no origin "HEAD:refs/heads/$destination" \
      || die 'publication failed or unresolved; retry only with identical context'
  fi
  probe_remote
  [ "$(printf '%s' "$REMOTE" | jq -r .head)" = "$head" ] || die 'published PR head could not be confirmed'
  printf '%s' "$REMOTE" | jq -e '.ci==null or .ci=="SUCCESS"' >/dev/null \
    || die 'published PR checks are not successful; reservation retained, retry identical context after checks settle'
  lock_state
  [ "$(printf '%s' "$JOURNAL" | jq -r .active.id)" = "$SEAT" ] || die 'repair ownership changed after publication'
  delivered=$(printf '%s' "$JOURNAL" | jq -c '.active.delivery.context // null')
  if [ "$delivered" = null ]; then
    delivered=$(printf '%s' "$candidate" | jq --argjson remote "$REMOTE" '
      .open_review_threads=[$remote.threads[] | select(.isResolved|not) |
        "Thread \(.id) on \($remote.url)"]')
    JOURNAL=$(printf '%s' "$JOURNAL" | jq --argjson ctx "$delivered" '.active.delivery.context=$ctx')
    atomic "$JOURNAL_PATH" "$JOURNAL"
  fi
  # Bind a stable read to the writer's serialized comparison; do not hold the
  # pending-state lock across its forge lookup or the separate metadata lock.
  context_hash=$(fm_pr_sha256 "$DATA/$TASK/pr-context.md")
  CTX=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-pr-context.sh" validate "$TASK" --json) \
    || die 'current context is unavailable after publication'
  [ "$context_hash" = "$(fm_pr_sha256 "$DATA/$TASK/pr-context.md")" ] || die 'context changed during validation'
  printf '%s' "$JOURNAL" | jq -e --argjson ctx "$CTX" \
    '$ctx==.active.context or $ctx==.active.delivery.context' >/dev/null || die 'original context changed during publication'
  unlock_state
  if ! jq -en --argjson ctx "$CTX" --argjson delivered "$delivered" '$ctx==$delivered' >/dev/null; then
    printf '%s\n' "$delivered" | FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-pr-context.sh" write "$TASK" --expect-hash "$context_hash" >/dev/null \
      || die 'cannot rewrite original context after publication'
  fi
  fm_pr_meta_rewrite "$META" "$STATE" .pr-repair-meta \
    'pr:pr_head:missing_review_override_ts:red_override_ts:red_override_pr:red_override_head:red_override_condition' \
    repair_meta_matches "pr=$URL" "pr_head=$head" || die 'cannot record repair PR identity'
  lock_state
  [ "$(printf '%s' "$JOURNAL" | jq -r .active.id)" = "$SEAT" ] || die 'repair ownership changed during context handoff'
  atomic "$JOURNAL_PATH" "$(printf '%s' "$JOURNAL" | jq '.active.phase="completed"')"
  finish_status
}

defer_worker() {
  local reason head context_hash deferred phase
  worker_open "$1" "$2"
  PUBLISH_LOCK="$STATE/.pr-repair-$SEAT.publish.lock"
  fm_lock_try_acquire "$PUBLISH_LOCK" || { PUBLISH_LOCK=; die 'publication is busy; retry identical input later'; }
  unlock_state
  validate_copy
  [ "$(git rev-parse --show-toplevel)" = "$COPY" ] || die 'defer outside the allocated repair copy'
  [ "$(git -C "$COPY" symbolic-ref --short HEAD)" = "$BRANCH" ] || die 'repair branch changed'
  require_debrief
  head=$(git -C "$COPY" rev-parse HEAD)
  WORK_DIR=$(mktemp -d "$DATA/$SEAT/.pr-repair.XXXXXX") || die 'cannot stage deferral'
  head -c 65537 > "$WORK_DIR/reason.txt"
  if [ "$(wc -c < "$WORK_DIR/reason.txt")" -gt 65536 ] || ! grep -q '[^[:space:]]' "$WORK_DIR/reason.txt"; then
    die 'reason must be nonempty and at most 64 KiB'
  fi
  reason=$(cat "$WORK_DIR/reason.txt")
  lock_state
  [ "$(printf '%s' "$JOURNAL" | jq -r .active.id)" = "$SEAT" ] || die 'repair ownership changed before deferral'
  phase=$(printf '%s' "$JOURNAL" | jq -r .active.phase)
  case "$phase" in active|launching|publishing|deferring|deferred) ;; *) die 'repair is not accepting a deferral' ;; esac
  context_hash=$(fm_pr_sha256 "$DATA/$TASK/pr-context.md")
  CTX=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-pr-context.sh" validate "$TASK" --json) \
    || die 'current context is unavailable'
  [ "$context_hash" = "$(fm_pr_sha256 "$DATA/$TASK/pr-context.md")" ] || die 'context changed during validation'
  printf '%s' "$JOURNAL" | jq -e --argjson ctx "$CTX" --arg reason "$reason" --arg head "$head" '
    .active.prepared==true and
    ($ctx==.active.context or $ctx==.active.delivery.context or $ctx==.active.deferral.context) and
    (.active.deferral==null or (.active.deferral.reason==$reason and .active.deferral.head==$head))' >/dev/null \
    || die 'context or earlier deferral changed; preserve it for owner review'
  if [ "$phase" = deferred ]; then
    finish_status "done: PR $URL deferred; reason recorded in context"
    return 0
  fi
  deferred=$(printf '%s' "$JOURNAL" | jq -c .active.deferral.context)
  if [ "$deferred" = null ]; then
    deferred=$(printf '%s' "$CTX" | jq --arg reason "Repair $SEAT: $reason" '.deferred_items=(.deferred_items+[$reason]|unique)')
  fi
  JOURNAL=$(printf '%s' "$JOURNAL" | jq --arg reason "$reason" --arg head "$head" --argjson ctx "$deferred" \
    '.active.phase="deferring" | .active.deferral={reason:$reason,head:$head,context:$ctx}')
  atomic "$JOURNAL_PATH" "$JOURNAL"
  unlock_state
  if ! jq -en --argjson ctx "$CTX" --argjson deferred "$deferred" '$ctx==$deferred' >/dev/null; then
    printf '%s\n' "$deferred" | FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-pr-context.sh" write "$TASK" --expect-hash "$context_hash" >/dev/null \
      || die 'cannot persist deferral context; its reason remains in the repair journal'
  fi
  fm_pr_meta_rewrite "$META" "$STATE" .pr-repair-meta \
    'pr:pr_head:missing_review_override_ts:red_override_ts:red_override_pr:red_override_head:red_override_condition' \
    repair_meta_matches "pr=$URL" "pr_head=$head" || die 'cannot record deferred PR identity'
  lock_state
  [ "$(printf '%s' "$JOURNAL" | jq -r .active.id)" = "$SEAT" ] || die 'repair ownership changed during deferral'
  atomic "$JOURNAL_PATH" "$(printf '%s' "$JOURNAL" | jq --arg id "$SEAT" --arg reason "$reason" \
    '.active.phase="deferred" | .escalation={id:$id,reason:$reason}')"
  finish_status "done: PR $URL deferred; reason recorded in context"
}

ready_worker() {
  local url=$2 head=$3 copy=$4 phase
  fm_pr_task_id_valid "$1" || return 1
  has_index "$1" || return 1
  repair_open "$1"
  [ "$URL" = "$url" ] || return 1
  META="$STATE/$SEAT.meta"
  fm_pr_private_file_valid "$META" 600 "$(fm_pr_file_device "$STATE")" || return 1
  [ "$(fm_backend_meta_exact_value "$META" pr)" = "$URL" ] &&
    [ "$(fm_backend_meta_exact_value "$META" pr_head)" = "$head" ] &&
    [ "$(fm_backend_meta_exact_value "$META" worktree)" = "$copy" ] || return 1
  phase=$(printf '%s' "$JOURNAL" | jq -r .active.phase)
  case "$phase" in
    completed)
      printf '%s' "$JOURNAL" | jq -e --arg head "$head" --argjson ctx "$CTX" \
        '.active.delivery.input.head==$head and .active.delivery.context==$ctx' >/dev/null || return 1 ;;
    deferred)
      printf '%s' "$JOURNAL" | jq -e --arg head "$head" --argjson ctx "$CTX" \
        '.active.deferral.head==$head and .active.deferral.context==$ctx' >/dev/null || return 1 ;;
    retiring)
      fm_pr_private_file_valid "$DATA/$SEAT/debrief.md" 600 "$(fm_pr_file_device "$DATA")" || return 1
      printf '%s' "$JOURNAL" | jq -e --arg head "$head" --arg copy "$copy" \
        --arg hash "$(fm_pr_sha256 "$DATA/$SEAT/debrief.md")" '
        .active.retirement.head==$head and .active.retirement.copy==$copy and
        .active.retirement.debrief_hash==$hash' >/dev/null || return 1 ;;
    *) return 1 ;;
  esac
  # A staged receipt follows confirmed physical cleanup. The old path may now
  # hold an unrelated pool allocation, so only unstaged rounds inspect it.
  if [ "$phase" != retiring ]; then
    [ -d "$copy" ] && [ "$(git -C "$copy" rev-parse HEAD)" = "$head" ] &&
      [ "$(git -C "$copy" symbolic-ref --short HEAD)" = "fm/$SEAT" ] || return 1
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-pr-context-watch.sh" owns "$URL" &&
    ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-pr-context-watch.sh" terminal "$TASK" >/dev/null; then return 1; fi
  printf '%s\n' "$phase"
}

retirement_stage() {
  local phase head copy meta recorded_url debrief_hash=''
  fm_pr_task_id_valid "$1" || die 'unsafe repair task'
  has_index "$1" || return 0
  repair_open "$1"
  phase=$(printf '%s' "$JOURNAL" | jq -r .active.phase)
  case "$phase" in
    retiring) return 0 ;;
    completed|deferred) ;;
    *) [ "${2:-}" = --cancel ] || die 'repair has not completed or recorded a deferral' ;;
  esac
  meta="$STATE/$SEAT.meta"
  fm_pr_private_file_valid "$meta" 600 "$(fm_pr_file_device "$STATE")" || die 'unsafe retiring metadata'
  head=$(fm_meta_optional_exact_value "$meta" pr_head) || die 'ambiguous retiring head'
  copy=$(fm_backend_meta_exact_value "$meta" worktree) || die 'missing retiring copy'
  recorded_url=$(fm_meta_optional_exact_value "$meta" pr) || die 'ambiguous retiring PR'
  if [ "${2:-}" = --cancel ]; then
    [ -z "$recorded_url" ] || [ "$recorded_url" = "$URL" ] || die 'retiring PR changed'
    head=$(printf '%s' "$JOURNAL" | jq -r '.active.deferral.head//.active.delivery.input.head//.active.snapshot.observed.head')
    JOURNAL=$(printf '%s' "$JOURNAL" | jq --arg id "$SEAT" '
      .active.outcome="cancelled" |
      .escalation={id:$id,reason:"Repair cancelled by explicit teardown; retained feedback requires owner review."}')
  else
    [ "$recorded_url" = "$URL" ] || die 'retiring PR changed'
    [ "$head" = "$(printf '%s' "$JOURNAL" | jq -r '.active.deferral.head//.active.delivery.input.head')" ] || die 'retiring head changed'
    JOURNAL=$(printf '%s' "$JOURNAL" | jq '.active.outcome=.active.phase')
  fi
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die 'invalid retiring head'
  if fm_pr_private_file_valid "$DATA/$SEAT/debrief.md" 600 "$(fm_pr_file_device "$DATA")"; then
    debrief_hash=$(fm_pr_sha256 "$DATA/$SEAT/debrief.md")
  fi
  atomic "$JOURNAL_PATH" "$(printf '%s' "$JOURNAL" | jq --arg head "$head" --arg copy "$copy" --arg hash "$debrief_hash" \
    '.active.phase="retiring" | .active.retirement={head:$head,copy:$copy,debrief_hash:$hash}')"
}

retired() {
  local line
  fm_pr_task_id_valid "$1" || die 'unsafe repair task'
  has_index "$1" || return 0
  repair_open "$1" retired
  [ ! -e "$STATE/$SEAT.meta" ] && [ ! -L "$STATE/$SEAT.meta" ] || die 'repair metadata still exists'
  if [ "$(printf '%s' "$JOURNAL" | jq '.active!=null')" = true ]; then
    [ "$(printf '%s' "$JOURNAL" | jq -r .active.phase)" = retiring ] || die 'retirement was not staged'
    JOURNAL=$(printf '%s' "$JOURNAL" | jq --argjson ctx "$CTX" '
      .active as $a | $a.snapshot.observed as $before |
      [$a.replies[]? | select(.phase=="confirmed")] as $own |
      def changed($items): . as $item | all($items[]?; .!=$item);
      {comments:([.pending[].feedback.comments[]? | select(changed($before.comments)) |
          select(.id as $id | all($own[]; .id!=$id))] | unique_by(.id)),
       reviews:([.pending[].feedback.reviews[]? | select(changed($before.reviews)) |
          select(.id as $id | all($own[]; .review_id!=$id))] | unique_by(.id)),
       threads:([.pending[].feedback.threads[]? | select(changed($before.threads)) |
          select(.comments.nodes[-1].id as $id | all($own[]; .id!=$id))] | unique_by(.id))} as $feedback |
      (.pending[-1]//$a.snapshot) as $latest |
      [if ($feedback.comments|length)>0 or ($feedback.threads|length)>0 then "comment" else empty end,
       if ($feedback.reviews|length)>0 then "review" else empty end,
       if $latest.observed_after_delivery==true then
         if $latest.ok==false then "unavailable"
         else (if $latest.observed.head!=$ctx.head then "head-moved" else empty end),
              (if (["FAILURE","ERROR"]|index($latest.observed.ci))!=null then "ci-red" else empty end) end
       else empty end] as $reasons |
      .last_outcome=$a | .active=null | .pending_feedback=$feedback |
      .last_generation=$a.snapshot.generation |
      if $a.outcome=="deferred" or $a.outcome=="cancelled" then
        .last_generation=([.last_generation]+[.pending[].generation]|max) |
        .outbox={sent:false,line:"pr-fix: \($ctx.pr_url|split("/")|last) \($ctx.head) \($a.outcome) \($ctx.pr_url) event=\(.last_generation)"}
      elif ($reasons|length)==0 then
        .last_generation=([.last_generation]+[.pending[].generation]|max) | .pending=[] | .outbox=null
      else
        .outbox={sent:false,line:("pr-fix: \($ctx.pr_url|split("/")|last) " +
          (if $latest.observed_after_delivery==true and $latest.ok then $latest.observed.head else $ctx.head end) +
          " \($reasons|join(",")) \($ctx.pr_url) event=\($latest.generation)")}
      end') || die 'cannot preserve retired feedback'
    atomic "$JOURNAL_PATH" "$JOURNAL"
  fi
  if [ "$(printf '%s' "$JOURNAL" | jq '.outbox!=null and .outbox.sent!=true')" = true ]; then
    line=$(printf '%s' "$JOURNAL" | jq -r .outbox.line)
    fm_wake_append check "pr-fix-retired-$SEAT" "$line" || die 'cannot queue pending repair feedback'
    JOURNAL=$(printf '%s' "$JOURNAL" | jq '.outbox.sent=true')
    atomic "$JOURNAL_PATH" "$JOURNAL"
  fi
  rm -f -- "$STATE/$SEAT.pr-repair.json"
  printf 'retired: %s %s\n' "$SEAT" "$URL"
}

archive_copy() { # <source> <destination> <expected-sha256>
  local source=$1 destination=$2 expected=$3
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    fm_pr_private_file_valid "$destination" 600 "$(fm_pr_file_device "${destination%/*}")" &&
      [ "$(fm_pr_sha256 "$destination")" = "$expected" ] || die 'archive destination differs from recorded evidence'
    return 0
  fi
  fm_pr_private_file_valid "$source" 600 "$(fm_pr_file_device "${source%/*}")" &&
    [ "$(fm_pr_sha256 "$source")" = "$expected" ] || die 'archive source differs from recorded evidence'
  TMP_FILE=$(mktemp "${destination%/*}/.archive-copy.XXXXXX") || die 'cannot stage archive evidence'
  cp -- "$source" "$TMP_FILE"
  chmod 600 "$TMP_FILE"
  [ "$(fm_pr_sha256 "$TMP_FILE")" = "$expected" ] || die 'archive copy failed verification'
  fm_pr_regular_destination_or_absent "$destination" || die 'unsafe archive destination'
  mv -f -- "$TMP_FILE" "$destination"
  TMP_FILE=
}

archive_context() {
  local dir plan manifest archive source_context source_snapshot name expected source home
  TASK=$1
  fm_pr_task_id_valid "$TASK" || die 'unsafe context task'
  fm_pcw_state_prepare "$STATE" "$FM_HOME" || die 'unsafe owning state directory'
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || die 'unsafe data store'
  DATA=$(CDPATH='' cd -- "$DATA" && pwd -P)
  dir="$DATA/$TASK" plan="$DATA/$TASK/pr-archive.json"
  [ -d "$dir" ] && [ ! -L "$dir" ] || die 'unsafe context directory'
  fm_pr_meta_lock_helpers
  CONTEXT_LOCK="$DATA/.pr-context-$TASK.lock"
  fm_lock_try_acquire "$CONTEXT_LOCK" || { CONTEXT_LOCK=; die 'context mutation is busy; retry'; }
  source_context="$dir/pr-context.md"
  source_snapshot="$STATE/pr-fix-$TASK.snapshot.json"
  if [ -e "$plan" ] || [ -L "$plan" ]; then
    fm_pr_private_file_valid "$plan" 600 "$(fm_pr_file_device "$dir")" || die 'unsafe archive manifest'
    manifest=$(jq -e --arg task "$TASK" '
      select(.schema==1 and .task==$task and (.url|type=="string") and
        (.directory|type=="string" and test("^pr-archive\\.[A-Za-z0-9]+$")) and
        ([.context_hash,.snapshot_hash,.journal_hash]|all(.[]; type=="string" and test("^[0-9a-f]{64}$"))))' "$plan") \
      || die 'invalid archive manifest'
    URL=$(printf '%s' "$manifest" | jq -r .url)
    fm_pr_url_parse "$URL" || die 'invalid archived PR'
    NUMBER=$FM_PR_NUMBER JOURNAL_PATH="$STATE/pr-fix-seat-$FM_PR_NUMBER.json"
    lock_state
  else
    load_context
    lock_state
    [ "$(printf '%s' "$JOURNAL" | jq '.active==null')" = true ] || die 'an active repair still owns this context'
    home=$FM_HOME
    FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-pr-context-watch.sh" retire "$home" "$TASK" >/dev/null || die 'terminal monitor is not ready for archival'
    [ "$CONTEXT_HASH" = "$(fm_pr_sha256 "$source_context")" ] || die 'context changed before archival'
    archive=$(mktemp -d "$dir/pr-archive.XXXXXX") || die 'cannot allocate archive'
    atomic "$archive/pr-repair.json" "$JOURNAL" "$archive"
    manifest=$(jq -cn --arg task "$TASK" --arg url "$URL" --arg directory "${archive##*/}" \
      --arg context_hash "$CONTEXT_HASH" --arg snapshot_hash "$(fm_pr_sha256 "$source_snapshot")" \
      --arg journal_hash "$(fm_pr_sha256 "$archive/pr-repair.json")" \
      '{schema:1,task:$task,url:$url,directory:$directory,context_hash:$context_hash,snapshot_hash:$snapshot_hash,journal_hash:$journal_hash}')
    atomic "$plan" "$manifest" "$dir"
  fi
  [ "$(printf '%s' "$JOURNAL" | jq '.active==null')" = true ] || die 'an active repair still owns the archive'
  archive="$dir/$(printf '%s' "$manifest" | jq -r .directory)"
  [ -d "$archive" ] && [ ! -L "$archive" ] && [ "$(fm_pr_file_mode "$archive")" = 700 ] &&
    [ "$(fm_pr_file_device "$archive")" = "$(fm_pr_file_device "$dir")" ] || die 'unsafe archive directory'
  for name in check.sh check-trust; do
    [ ! -e "$STATE/pr-fix-$TASK.$name" ] && [ ! -L "$STATE/pr-fix-$TASK.$name" ] || die 'monitor reappeared during archival'
  done
  fm_pr_private_file_valid "$archive/pr-repair.json" 600 "$(fm_pr_file_device "$dir")" &&
    [ "$(fm_pr_sha256 "$archive/pr-repair.json")" = "$(printf '%s' "$manifest" | jq -r .journal_hash)" ] \
    || die 'archived repair journal changed'
  archive_copy "$source_context" "$archive/pr-context.md" "$(printf '%s' "$manifest" | jq -r .context_hash)"
  archive_copy "$source_snapshot" "$archive/snapshot.json" "$(printf '%s' "$manifest" | jq -r .snapshot_hash)"
  # Only remove sources after both verified copies exist. A failed unlink keeps
  # the manifest so the next cycle resumes, rather than inventing a new archive.
  for name in snapshot context; do
    source=$source_snapshot
    [ "$name" != context ] || source=$source_context
    if [ -e "$source" ] || [ -L "$source" ]; then
      expected=$(printf '%s' "$manifest" | jq -r --arg key "${name}_hash" '.[$key]')
      fm_pr_private_file_valid "$source" 600 "$(fm_pr_file_device "${source%/*}")" &&
        [ "$(fm_pr_sha256 "$source")" = "$expected" ] || die 'archive source changed before removal'
      rm -f -- "$source" || die 'archive source removal interrupted; retry reconciliation'
    fi
  done
  atomic "$JOURNAL_PATH" "$(printf '%s' "$JOURNAL" | jq '.archived=true')"
  fm_pr_regular_destination_or_absent "$archive/manifest.json" || die 'unsafe completed archive manifest'
  mv -f -- "$plan" "$archive/manifest.json"
  printf 'archived: %s %s\n' "$TASK" "$URL"
}

reconcile() {
  local index id file task rc=0
  for index in "$STATE"/*.pr-repair.json; do
    [ -e "$index" ] || [ -L "$index" ] || continue
    id=${index##*/}; id=${id%.pr-repair.json}
    [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || continue
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$0" retired "$id" || rc=1
  done
  for file in "$DATA"/*/pr-archive.json; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    task=${file%/pr-archive.json}; task=${task##*/}
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" "$0" archive "$task" || rc=1
  done
  for file in "$DATA"/*/pr-context.md; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    task=${file%/pr-context.md}; task=${task##*/}
    [ ! -e "$DATA/$task/pr-archive.json" ] && [ ! -L "$DATA/$task/pr-archive.json" ] || continue
    if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
        "$SCRIPT_DIR/fm-pr-context-watch.sh" terminal "$task" >/dev/null 2>&1; then
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" "$0" archive "$task" || rc=1
    fi
  done
  return "$rc"
}

start() {
  local project='' arg value attestation=0 harness=0 rc=0 seat round spec intent
  local -a routing=()
  TASK=$1; shift
  if [ "${1:-}" = --project ]; then
    [ "$#" -ge 2 ] || die '--project requires a clone'
    project=$2; shift 2
  fi
  [ "${1:-}" = -- ] || die 'supply the existing dispatch selection after --'
  shift
  while [ "$#" -gt 0 ]; do
    arg=$1; shift
    case "$arg" in
      --dispatch-resolved|--dispatch-tachikoma)
        attestation=$((attestation + 1)); routing+=("$arg") ;;
      --harness|--model|--effort|--account-profile|--task-class|--backend|--routing-source|--matched-rule|--quota-decision|--quota-headroom|--quota-runway|--dispatch-provider|--dispatch-model-family|--dispatch-override-reason)
        [ "$#" -gt 0 ] || die "missing value for $arg"
        value=$1; shift
        case "$value" in ''|--*|*$'\n'*|*$'\r'*) die "invalid value for $arg" ;; esac
        [ "$arg" != --harness ] || harness=1
        [ "$arg" != --dispatch-override-reason ] || attestation=$((attestation + 1))
        routing+=("$arg" "$value") ;;
      *) die "unsupported routing argument: $arg" ;;
    esac
  done
  [ "$attestation" -eq 1 ] || die 'exactly one dispatch attestation is required'
  if [ "$harness" -ne 1 ]; then
    [ "${routing[0]:-}" = --dispatch-tachikoma ] || die 'an explicitly selected harness is required'
  fi
  load_context
  SNAPSHOT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-pr-context-watch.sh" inspect "$TASK") || die 'a fresh successful registered monitor snapshot is required'
  [ "$(printf '%s' "$SNAPSHOT" | jq -r .observed.state)" = OPEN ] || die 'terminal PRs must be archived, not repaired'
  if [ -z "$project" ]; then
    if project_matches "$FM_HOME"; then project=$FM_HOME
    else project="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/${REPO##*/}"; fi
  fi
  project_matches "$project" || die 'project origin does not match the context head repository'
  project=$(CDPATH='' cd -- "$project" && pwd -P)
  lock_state
  [ -f "$DATA/$TASK/pr-context.md" ] && [ "$CONTEXT_HASH" = "$(fm_pr_sha256 "$DATA/$TASK/pr-context.md")" ] &&
    [ "$CONTEXT_HASH" = "$(printf '%s' "$SNAPSHOT" | jq -r .context_hash)" ] || die 'context changed before repair reservation'
  if [ "$(printf '%s' "$JOURNAL" | jq -r '.active != null')" = true ]; then
    record_pending
    printf 'active: %s %s\n' "$(printf '%s' "$JOURNAL" | jq -r .active.id)" "$URL"
    return 0
  fi
  if [ "$(printf '%s' "$SNAPSHOT" | jq .generation)" -le "$(printf '%s' "$JOURNAL" | jq .last_generation)" ]; then return 0; fi
  [ "$(printf '%s' "$JOURNAL" | jq '.escalation==null')" = true ] || die 'stopped repair requires owner reconciliation; see the context and repair journal'
  # Rebase preserved pending identities onto the current PR observation; their
  # arrival predates the new delivery baseline but not the previous repair.
  SNAPSHOT=$(printf '%s' "$SNAPSHOT" | jq --argjson pending "$(printf '%s' "$JOURNAL" | jq '.pending_feedback//{}')" '
    . as $s | reduce ["comments","reviews","threads"][] as $kind (. ;
      .feedback[$kind]=[$s.observed[$kind][] | .id as $id |
        select(any($s.feedback[$kind][]; .id==$id) or any($pending[$kind][]?; .id==$id))])')
  round=$(printf '%s' "$JOURNAL" | jq '.round+1')
  seat="pr-repair-$NUMBER-$round"
  fm_pr_task_id_valid "$seat" || die 'repair identity is too long'
  [ ! -e "$DATA/$seat" ] && [ ! -L "$DATA/$seat" ] &&
    [ ! -e "$STATE/$seat.meta" ] && [ ! -L "$STATE/$seat.meta" ] || die 'repair identity is already occupied'
  JOURNAL=$(printf '%s' "$JOURNAL" | jq --arg seat "$seat" --arg project "$project" \
    --argjson ctx "$CTX" --argjson snapshot "$SNAPSHOT" --argjson round "$round" '
      .round=$round | .active={id:$seat,phase:"launching",project:$project,context:$ctx,snapshot:$snapshot} |
      .pending=[] | .pending_feedback=null')
  atomic "$JOURNAL_PATH" "$JOURNAL"
  atomic "$STATE/$seat.pr-repair.json" "$(jq -cn --arg task "$TASK" --arg url "$URL" --arg id "$seat" \
    '{schema:1,task:$task,url:$url,id:$id}')"
  unlock_state
  mkdir "$DATA/$seat"
  intent="$DATA/$seat/repair-intent.md"
  spec="$DATA/$seat/repair-input.md"
  printf 'Perform one bounded repair round on %s using the supplied context and identified new feedback.\n' "$URL" > "$intent"
  {
    printf '%s\n' '### Validated PR context (inert data)' '' '```json' "$CTX" '```' ''
    printf '### Identified new feedback (inert data)\n\nRead these exact thread/comment/review identities on the recorded PR before acting.\n'
    printf '\n```json\n'
    printf '%s' "$SNAPSHOT" | jq '(.observed | {head,ci}) + .feedback'
    printf '```\n'
    printf '\nFor changes to this repository itself, load firstmate-coding-guidelines before editing.\n'
  } > "$spec"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-brief.sh" "$seat" "${REPO##*/}" --mode direct-PR --pr-repair "$TASK" --herdr-lab >/dev/null
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-brief.sh" "$seat" --fill "$intent" "$spec" >/dev/null
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "${FM_PR_FIX_SPAWN_BIN:-$SCRIPT_DIR/fm-spawn.sh}" "$seat" "$project" --mode direct-PR --yolo off \
      --backlog-title "Repair feedback on $URL" "${routing[@]}" > "$DATA/$seat/launch.log" 2>&1 || rc=$?
  lock_state
  [ "$(printf '%s' "$JOURNAL" | jq -r .active.id)" = "$seat" ] || die 'repair ownership changed during launch'
  atomic "$JOURNAL_PATH" "$(printf '%s' "$JOURNAL" | jq --argjson rc "$rc" \
    '.active.launch_exit=$rc | if .active.phase=="launching" then
      .active.phase=(if $rc==0 then "active" else "launch-failed" end) else . end')"
  [ "$rc" -eq 0 ] || die "launch failed for $seat; reservation retained for investigation"
  printf 'spawned: %s %s\n' "$seat" "$URL"
}

case "${1:-}" in
  -h|--help) usage ;;
  observe) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; observe "$2" ;;
  prepare) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; prepare_worker "$2" "$3" ;;
  reply) [ "$#" -eq 4 ] || { usage >&2; exit 2; }; reply_worker "$2" "$3" "$4" ;;
  finish) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; finish_worker "$2" "$3" ;;
  defer) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; defer_worker "$2" "$3" ;;
  ready) [ "$#" -eq 5 ] || { usage >&2; exit 2; }; ready_worker "$2" "$3" "$4" "$5" ;;
  retirement-stage)
    if [ "$#" -eq 2 ]; then retirement_stage "$2"
    elif [ "$#" -eq 3 ] && [ "$3" = --cancel ]; then retirement_stage "$2" "$3"
    else usage >&2; exit 2; fi
    ;;
  retired) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; retired "$2" ;;
  archive) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; archive_context "$2" ;;
  reconcile) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; reconcile ;;
  '') usage >&2; exit 2 ;;
  *) start "$@" ;;
esac
