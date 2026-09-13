#!/usr/bin/env bash
# Install a private PR monitor from a validated context, independently of its copy.
# Usage: fm-pr-context-watch.sh install <home> [task]
#        fm-pr-context-watch.sh poll <task>
#        fm-pr-context-watch.sh ack <task> <exact-emitted-line>
#        fm-pr-context-watch.sh ready <task> <PR-URL> <delivered-head> <copy>
#        fm-pr-context-watch.sh inspect <task>
#        fm-pr-context-watch.sh probe <task>
#        fm-pr-context-watch.sh terminal <task>
#        fm-pr-context-watch.sh owns <PR-URL>
#        fm-pr-context-watch.sh retire <home> <task>
#        fm-pr-context-watch.sh --help
# install binds pr-fix-<task>.check.sh through fm-check-register.sh; omitted task
# discovers data/*/pr-context.md. The owning home's bin must contain this helper.
# Each check has the existing runner's timeout and batch fairness, not a daemon.
# poll prints only pr-fix: <number> <exact-head> <reason> <URL> event=<generation>.
# Events persist before output and coalesce for 600 seconds between emissions.
# The repair lifecycle observes each generation before snapshot publication so
# an active round retains feedback even while the wake is being debounced.
# ack is for the check runner AFTER durable queue publication, not mere printing.
# An older generation cannot consume changes observed during delivery.
# ready permits only a matching, successful open-PR snapshot at most 600 seconds
# old, with no unqueued events and no red/pending CI. Home, data and monitor code
# must survive the copy. It never bypasses ordinary teardown or grants a merge.
# inspect exports a fresh, successful, context-bound snapshot for repair intake.
# It does not acknowledge the outbox or grant cleanup/merge authority.
# probe performs a fresh read for a registered context without advancing the
# snapshot or outbox; mutation callers must still check their expected head.
# terminal exports acknowledged, context-bound terminal evidence, including when
# its check was already retired. retire uses this same gate before unregistering.
# First observation and changed context hashes baseline feedback at the context
# file's write time (whole seconds), recorded in snapshot.baseline. Activity in
# that second or later wakes: coarse timestamps cannot order boundary events,
# so an extra wake is safer than lost feedback. Strictly older history stays
# suppressed; later observed review/thread state changes remain actionable.
# snapshot.feedback is the actionable subset used for repair briefing and reply
# authorization. State-change identities survive unchanged polls until the next
# delivery baseline; snapshot.observed always preserves the full source history.
# gh-axi responses and context commands are data, never shell source.
# Incomplete or failed forge reads preserve evidence and announce unavailable.
# The snapshot/outbox is state/pr-fix-<task>.snapshot.json (mode 0600).
# Terminal merged/closed events survive removal of the original merge check.
# After handling one, retire removes only its registered check; it requires an
# acknowledged terminal snapshot matching the context, and retains all evidence.
# FM_HOME, FM_STATE_OVERRIDE and FM_DATA_OVERRIDE bind the owning stores.
# FM_PR_CONTEXT_GH_CMD and FM_PR_CONTEXT_NOW are deterministic test seams.
set -eu
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
GH_CMD=${FM_PR_CONTEXT_GH_CMD:-gh-axi}
LOCK='' CONTEXT_LOCK='' TMP_FILE=''
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-comment-watch-lib.sh
. "$SCRIPT_DIR/fm-pr-comment-watch-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
die() { printf 'error: PR context monitor: %s\n' "$*" >&2; exit 1; }
cleanup() {
  [ -z "$TMP_FILE" ] || rm -f -- "$TMP_FILE"
  [ -z "$LOCK" ] || fm_lock_release "$LOCK"
  [ -z "$CONTEXT_LOCK" ] || fm_lock_release "$CONTEXT_LOCK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

prepare() {
  fm_pcw_state_prepare "$STATE" "$FM_HOME" || die 'unsafe owning state directory'
  FM_HOME=$(CDPATH='' cd -- "$FM_HOME" && pwd -P)
  STATE=$(CDPATH='' cd -- "$STATE" && pwd -P)
  [ ! -L "$DATA" ] || die 'linked data directory'
  DATA=$(CDPATH='' cd -- "$DATA" && pwd -P) || die 'missing data directory'
}
context() {
  fm_pr_task_id_valid "$1" || return 1
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-pr-context.sh" validate "$1" --json
}
shim() {
  printf '#!/usr/bin/env bash\nFM_HOME=%q FM_STATE_OVERRIDE=%q FM_DATA_OVERRIDE=%q exec %q poll %q\n' \
    "$FM_HOME" "$STATE" "$DATA" "$FM_HOME/bin/fm-pr-context-watch.sh" "$1"
}
installed() {
  fm_custom_check_registered "$STATE" "pr-fix-$1" &&
    [ "$(cat "$STATE/pr-fix-$1.check.sh")" = "$(shim "$1")" ]
}
atomic() { # <path> <mode> <content>
  fm_pr_regular_destination_on_device_or_absent "$1" "$(fm_pr_file_device "$STATE")" || return 1
  TMP_FILE=$(mktemp "$STATE/.pr-context-watch.XXXXXX") || return 1
  printf '%s\n' "$3" > "$TMP_FILE" && chmod "$2" "$TMP_FILE" && mv -f -- "$TMP_FILE" "$1" || return 1
  TMP_FILE=
}
matching_contexts() {
  local file task value
  for file in "$DATA"/*/pr-context.md; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    task=${file%/pr-context.md}; task=${task##*/}
    value=$(context "$task" 2>/dev/null) || continue
    [ "$(printf '%s' "$value" | jq -r .pr_url)" = "$1" ] || continue
    printf '%s\n' "$task"
  done
}
owns() {
  local task
  prepare
  fm_pr_url_parse "$1" || return 1
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    installed "$task" && return 0
  done < <(matching_contexts "$1")
  return 1
}
install_one() {
  local task=$1 check want ctx other
  fm_pr_task_id_valid "$task" || die 'unsafe context task'
  fm_pr_meta_lock_helpers
  CONTEXT_LOCK="$DATA/.pr-context-$task.lock"
  fm_lock_try_acquire "$CONTEXT_LOCK" || { CONTEXT_LOCK=; die 'context mutation is busy; retry'; }
  [ ! -e "$DATA/$task/pr-archive.json" ] && [ ! -L "$DATA/$task/pr-archive.json" ] || die 'context archival is in progress'
  ctx=$(context "$task") || die "invalid context: $task"
  while IFS= read -r other; do
    [ "$other" = "$task" ] || die "duplicate context ownership: $task and $other"
  done < <(matching_contexts "$(printf '%s' "$ctx" | jq -r .pr_url)")
  check="$STATE/pr-fix-$task.check.sh"
  want=$(shim "$task")
  if [ -e "$check" ] || [ -L "$check" ]; then
    fm_pr_private_file_valid "$check" 700 "$(fm_pr_file_device "$STATE")" &&
      [ "$(cat "$check")" = "$want" ] || die "check belongs to a different or untrusted installation: $task"
  else
    atomic "$check" 700 "$want" || die 'cannot install check'
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "pr-fix-$task" >/dev/null
  fm_lock_release "$CONTEXT_LOCK" || die 'cannot release context lock'
  CONTEXT_LOCK=
  printf 'installed: pr-fix-%s\n' "$task"
}

query() {
  cat <<'GRAPHQL'
query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) { pullRequest(number:$number) {
    url state headRefOid headRefName headRepository { nameWithOwner defaultBranchRef { name } }
    comments(first:100) { pageInfo { hasNextPage } nodes { id updatedAt } }
    reviews(first:100) { pageInfo { hasNextPage } nodes { id state submittedAt } }
    reviewThreads(first:100) { pageInfo { hasNextPage } nodes {
      id isResolved comments(last:1) { nodes { id updatedAt } }
    } }
    commits(last:1) { nodes { commit { statusCheckRollup { state } } } }
  } }
}
GRAPHQL
}
fetch() { # <validated-context-json> -> canonical remote snapshot
  local ctx=$1 url owner repo number wire
  url=$(printf '%s' "$ctx" | jq -r .pr_url)
  fm_pr_url_parse "$url" || return 1
  owner=${FM_PR_PATH%%/*} repo=${FM_PR_PATH#*/} number=$FM_PR_NUMBER
  # ponytail: refuse collections over 100; add pagination if that ceiling is reached.
  # Like the module forge adapter, project flat JSON-string rows before TOON's
  # string clamp, then decode only that narrow shape (not arbitrary TOON).
  # shellcheck disable=SC2016 # These dollar identifiers belong to jq, not the shell.
  wire=$(GH_HOST=github.com "$GH_CMD" api POST graphql --field "query=$(query)" --field "owner=$owner" \
    --field "name=$repo" --field "number=$number" --jq '
      if (.errors // [] | length) > 0 then error("GraphQL errors") else . end |
      .data.repository.pullRequest as $p |
      if ([$p.comments.nodes,$p.reviews.nodes,$p.reviewThreads.nodes] |
          all(.[]; type=="array" and length<=100)) and
        ($p.commits.nodes|type=="array" and length==1) and
        ($p.commits.nodes[0].commit|type=="object" and has("statusCheckRollup") and
          (.statusCheckRollup==null or (.statusCheckRollup|type=="object" and (.state|type=="string"))))
      then . else error("incomplete collections or commit") end |
      {m:({url:$p.url,head:$p.headRefOid,repo:$p.headRepository.nameWithOwner,
        branch:$p.headRefName,state:$p.state,default_branch:$p.headRepository.defaultBranchRef.name,
        ci:$p.commits.nodes[0].commit.statusCheckRollup.state,
        complete:([$p.comments,$p.reviews,$p.reviewThreads] | all(.[]; .pageInfo.hasNextPage == false)),
        counts:[($p.comments.nodes|length),($p.reviews.nodes|length),($p.reviewThreads.nodes|length)]}|tojson)} +
      ([($p.comments.nodes | to_entries[] | {key:("c"+(.key|tostring)),value:(.value|tojson)}),
        ($p.reviews.nodes | to_entries[] | {key:("r"+(.key|tostring)),value:(.value|tojson)}),
        ($p.reviewThreads.nodes | to_entries[] | {key:("t"+(.key|tostring)),value:(.value|tojson)})] | from_entries)
    ' </dev/null) || return 1
  printf '%s\n' "$wire" | jq -Rse --argjson ctx "$ctx" '
    "^(?<key>m|[crt][0-9]+): (?<json>\".*\")$" as $pattern |
    split("\n") | map(select(length>0) |
      if test($pattern) then capture($pattern) else error("unexpected wire row") end |
      {key:.key,value:(.json|fromjson|fromjson)}) |
    if (map(.key)|unique|length) != length then error("duplicate rows") else . end |
    from_entries as $rows | $rows.m as $m |
    def group($prefix): [$rows|to_entries[]|select(.key|startswith($prefix))|.value] | sort_by(.id);
    group("c") as $comments | group("r") as $reviews | group("t") as $threads |
    def text: type=="string" and length>0;
    def identities: all(.[]; .id|text) and length==(map(.id)|unique|length);
    def timestamp: type=="string" and (try (fromdateiso8601|type=="number") catch false);
    def comment: (.id|text) and (.updatedAt|timestamp);
    if ([$comments,$reviews,$threads]|all(.[]; identities)|not) or
      ($comments|all(.[]; comment)|not) or
      ($reviews|all(.[]; .state as $s |
        (["APPROVED","CHANGES_REQUESTED","COMMENTED","DISMISSED","PENDING"]|index($s))!=null and
        (.submittedAt==null or (.submittedAt|timestamp)))|not) or
      ($threads|all(.[]; (.isResolved|type=="boolean") and
        (.comments.nodes|type=="array" and length<=1 and all(.[]; comment)))|not)
    then error("malformed or duplicate identities") else . end |
    if $m.url != $ctx.pr_url or $m.repo != $ctx.repo or $m.branch != $ctx.branch or
      ($m.head|type != "string" or (test("^[0-9a-f]{40}$")|not)) or
      (["OPEN","CLOSED","MERGED"]|index($m.state)) == null or
      ([null,"SUCCESS","PENDING","EXPECTED","FAILURE","ERROR"]|index($m.ci)) == null or
      $m.complete != true or $m.counts != [($comments|length),($reviews|length),($threads|length)]
    then error("incomplete or mismatched PR") else
      $m | del(.complete,.counts) | . + {comments:$comments,reviews:$reviews,threads:$threads}
    end
  '
}

snapshot_open() { # <task> <context-json>; holds lock until process exit
  local task=$1 ctx=$2
  fm_pr_meta_lock_helpers
  LOCK="$STATE/.pr-fix-$task.lock"
  fm_lock_try_acquire "$LOCK" || { LOCK=; return 1; }
  if ! installed "$task"; then
    [ "${3:-}" = retiring ] &&
      [ ! -e "$STATE/pr-fix-$task.check.sh" ] && [ ! -L "$STATE/pr-fix-$task.check.sh" ] &&
      [ ! -e "$STATE/pr-fix-$task.check-trust" ] && [ ! -L "$STATE/pr-fix-$task.check-trust" ] \
      || die 'check is not canonically registered'
  fi
  SNAPSHOT_PATH="$STATE/pr-fix-$task.snapshot.json"
  SNAPSHOT='{}'
  if [ -e "$SNAPSHOT_PATH" ] || [ -L "$SNAPSHOT_PATH" ]; then
    fm_pr_private_file_valid "$SNAPSHOT_PATH" 600 "$(fm_pr_file_device "$STATE")" || die 'unsafe snapshot'
    SNAPSHOT=$(jq -e --arg task "$task" --arg url "$(printf '%s' "$ctx" | jq -r .pr_url)" '
      select(.schema==1 and .task==$task and .url==$url and
        (.generation|type=="number" and .>=0 and .<2147483647 and .==floor) and
        (.last_emit|type=="number" and .>=0 and .==floor) and
        (.pending|type=="array" and all(.[]; . as $r |
          ["comment","review","ci-red","head-moved","unavailable","merged","closed"]|index($r)!=null)) and
        (.baseline==null or (.baseline|(.context_hash|type=="string" and test("^[0-9a-f]{64}$")) and
          (.delivered_at|type=="number" and .>=0 and .==floor))) and
        (.context_head|type=="string" and test("^[0-9a-f]{40}$")) and
        (.observed==null or (.observed|.url==$url and (.head|type=="string" and test("^[0-9a-f]{40}$")))) and
        (.ok|type=="boolean"))' "$SNAPSHOT_PATH") || die 'invalid snapshot'
  fi
}
event_line() {
  jq -r '"pr-fix: \(.url|split("/")|last) \(.observed.head//.context_head) \(.pending|join(",")) \(.url) event=\(.generation)"'
}
ack() {
  local ctx
  prepare
  ctx=$(context "$1") || die 'invalid context'
  snapshot_open "$1" "$ctx" || return 1
  [ "$(printf '%s' "$SNAPSHOT" | jq '.pending|length')" -gt 0 ] || return 1
  [ "$2" = "$(printf '%s' "$SNAPSHOT" | event_line)" ] || return 1
  atomic "$SNAPSHOT_PATH" 600 "$(printf '%s' "$SNAPSHOT" | jq '.pending=[]')"
}
probe() {
  local ctx
  prepare
  ctx=$(context "$1") || return 1
  installed "$1" || return 1
  fetch "$ctx"
}
inspect() {
  local ctx now hash
  prepare
  ctx=$(context "$1") || return 1
  snapshot_open "$1" "$ctx" || return 1
  now=${FM_PR_CONTEXT_NOW:-$(date +%s)}
  [[ "$now" =~ ^[0-9]{1,10}$ ]] || return 1
  hash=$(fm_pr_sha256 "$DATA/$1/pr-context.md")
  printf '%s' "$SNAPSHOT" | jq -e --argjson ctx "$ctx" --arg hash "$hash" --argjson now "$now" '
    select(.ok and .context_hash==$hash and .context_head==$ctx.head and
      .observed.url==$ctx.pr_url and .observed.repo==$ctx.repo and .observed.branch==$ctx.branch and
      (.observed.state as $s | ["OPEN","CLOSED","MERGED"]|index($s)!=null) and
      ([.observed.comments,.observed.reviews,.observed.threads,
        .feedback.comments,.feedback.reviews,.feedback.threads]|all(.[];type=="array")) and
      .at<=$now and ($now-(.at//0))<=600)
  '
}
ready() {
  local task=$1 url=$2 head=$3 copy=$4 ctx hash now code
  prepare
  ctx=$(context "$task") || return 1
  copy=$(CDPATH='' cd -- "$copy" && pwd -P) || return 1
  code=$(CDPATH='' cd -- "$FM_HOME/bin" && pwd -P) || return 1
  case "$FM_HOME/" in "$copy/"*) return 1 ;; esac
  case "$DATA/" in "$copy/"*) return 1 ;; esac
  case "$code/" in "$copy/"*) return 1 ;; esac
  [ ! -L "$FM_HOME/bin/fm-pr-context-watch.sh" ] || return 1
  [ "$(git -C "$copy" rev-parse --show-toplevel)" = "$copy" ] || return 1
  [ "$(git -C "$copy" rev-parse HEAD)" = "$head" ] || return 1
  [ "$(git -C "$copy" symbolic-ref --short HEAD)" = "$(printf '%s' "$ctx" | jq -r .branch)" ] || return 1
  snapshot_open "$task" "$ctx" || return 1
  hash=$(fm_pr_sha256 "$DATA/$task/pr-context.md")
  now=${FM_PR_CONTEXT_NOW:-$(date +%s)}
  [[ "$now" =~ ^[0-9]{1,10}$ ]] || return 1
  printf '%s' "$SNAPSHOT" | jq -e --argjson ctx "$ctx" --arg hash "$hash" --arg url "$url" \
    --arg head "$head" --argjson now "$now" '
      .ok and .context_hash==$hash and .url==$url and $ctx.pr_url==$url and
      .context_head==$head and $ctx.head==$head and .observed.head==$head and
      .observed.repo==$ctx.repo and .observed.branch==$ctx.branch and .observed.state=="OPEN" and (.observed.ci==null or .observed.ci=="SUCCESS") and
      (.pending|length)==0 and .at<=$now and ($now-(.at//0))<=600
    ' >/dev/null
}
terminal() {
  local ctx hash
  prepare
  ctx=$(context "$1") || return 1
  snapshot_open "$1" "$ctx" retiring || return 1
  hash=$(fm_pr_sha256 "$DATA/$1/pr-context.md")
  printf '%s' "$SNAPSHOT" | jq -e --arg hash "$hash" '
    .ok and .context_hash==$hash and (.pending|length)==0 and
    (.observed.state=="MERGED" or .observed.state=="CLOSED")' >/dev/null || return 1
  printf '%s\n' "$SNAPSHOT"
}
retire() {
  terminal "$1" >/dev/null || return 1
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "pr-fix-$1"
}
poll() {
  local task=$1 ctx old remote now hash next line delivered
  prepare
  ctx=$(context "$task") || die 'invalid context'
  snapshot_open "$task" "$ctx" || return 0
  old=$SNAPSHOT
  now=${FM_PR_CONTEXT_NOW:-$(date +%s)}
  [[ "$now" =~ ^[0-9]{1,10}$ ]] || die 'invalid time'
  hash=$(fm_pr_sha256 "$DATA/$task/pr-context.md")
  delivered=$(fm_path_mtime "$DATA/$task/pr-context.md") || die 'cannot read context delivery time'
  [[ "$delivered" =~ ^[0-9]{1,10}$ ]] || die 'invalid context delivery time'
  remote=$(fetch "$ctx" 2>/dev/null) || remote=null
  [ "$hash" = "$(fm_pr_sha256 "$DATA/$task/pr-context.md")" ] || die 'context changed during poll; retry'
  next=$(jq -cn --argjson old "$old" --argjson remote "$remote" --argjson ctx "$ctx" \
    --arg hash "$hash" --argjson now "$now" --argjson delivered "$delivered" '
    ($old.baseline.context_hash!=$hash or $old.observed==null) as $reset |
    (if $reset then {context_hash:$hash,delivered_at:$delivered} else $old.baseline end) as $baseline |
    def newer: (.//"1970-01-01T00:00:00Z"|fromdateiso8601)>=$baseline.delivered_at;
    def feedback: {
      comments:[.comments[]?|select(.updatedAt|newer)],
      reviews:[.reviews[]?|select(.submittedAt|newer)],
      threads:[.threads[]?|select(any(.comments.nodes[]?; .updatedAt|newer))]};
    def state_changed($before;$after;$key):
      ($reset|not) and any($after[]?; . as $item |
        any($before[]?; .id==$item.id and .[$key]!=$item[$key]));
    def retained($items): .id as $id | ($reset|not) and any($items[]?; .id==$id);
    ($remote|feedback) as $fresh |
    (if $reset then {} else ($old.observed|feedback) end) as $seen |
    (if $remote==null then $old.feedback else {
      comments:$fresh.comments,
      reviews:[$remote.reviews[] | select((.submittedAt|newer) or retained($old.feedback.reviews) or
        state_changed($old.observed.reviews;[.];"state"))],
      threads:[$remote.threads[] | select(any(.comments.nodes[]?; .updatedAt|newer) or
        retained($old.feedback.threads) or state_changed($old.observed.threads;[.];"isResolved"))]
    } end) as $actionable |
    ($old + {schema:1,task:$ctx.task,url:$ctx.pr_url,context_hash:$hash,context_head:$ctx.head,
      baseline:(if $remote==null then $old.baseline else $baseline end),
      generation:($old.generation//0),last_emit:($old.last_emit//0),
      pending:(if $reset and $remote!=null then
        ($old.pending//[])-["comment","review"]-(if $remote.head==$ctx.head then ["head-moved"] else [] end)
        else ($old.pending//[]) end),at:$now}) as $s |
    (if $remote == null then (if $old.ok == false then [] else ["unavailable"] end)
    elif $remote.state != "OPEN" then
      (if $remote.state != $old.observed.state then [$remote.state|ascii_downcase] else [] end)
    else
      [if $fresh.comments != ($seen.comments//[]) or $fresh.threads != ($seen.threads//[]) or
          state_changed($old.observed.threads;$remote.threads;"isResolved")
        then "comment" else empty end,
       if $fresh.reviews != ($seen.reviews//[]) or state_changed($old.observed.reviews;$remote.reviews;"state")
        then "review" else empty end,
       if (["FAILURE","ERROR"]|index($remote.ci)) != null and $remote.ci != $old.observed.ci
        then "ci-red" else empty end,
       if $remote.head != $ctx.head and $remote.head != $old.observed.head then "head-moved" else empty end]
    end) as $changed |
    $s + {ok:($remote!=null),observed:($remote//$old.observed),feedback:$actionable,
      generation:($s.generation + (if ($changed|length)>0 then 1 else 0 end)),
      pending:(if $remote!=null and $remote.state!="OPEN" and ($changed|length)>0
        then $changed else ($s.pending+$changed|unique) end)} |
    .emit = ((.pending|length)>0 and (.last_emit==0 or $now<.last_emit or $now-.last_emit>=600)) |
    if .emit then .last_emit=$now else . end
  ') || die 'cannot compute snapshot'
  printf '%s' "$next" | jq 'del(.emit)' |
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-pr-fix-seat.sh" observe "$task" || die 'cannot retain active repair feedback'
  atomic "$SNAPSHOT_PATH" 600 "$(printf '%s' "$next" | jq 'del(.emit)')" || die 'cannot persist snapshot'
  if [ "$(printf '%s' "$next" | jq -r .emit)" = true ]; then
    line=$(printf '%s' "$next" | event_line)
    printf '%s\n' "$line"
  fi
}

case "${1:-}" in
  -h|--help) usage ;;
  install)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }
    FM_HOME=$2 STATE=${FM_STATE_OVERRIDE:-$2/state} DATA=${FM_DATA_OVERRIDE:-$2/data}
    prepare
    [ -x "$FM_HOME/bin/fm-pr-context-watch.sh" ] || die 'install the helper in the owning home first'
    if [ "$#" -eq 3 ]; then install_one "$3"; else
      for file in "$DATA"/*/pr-context.md; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        task=${file%/pr-context.md}; install_one "${task##*/}"
      done
    fi
    ;;
  poll) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; poll "$2" ;;
  ack) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; ack "$2" "$3" ;;
  ready) [ "$#" -eq 5 ] || { usage >&2; exit 2; }; ready "$2" "$3" "$4" "$5" ;;
  inspect) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; inspect "$2" ;;
  probe) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; probe "$2" ;;
  terminal) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; terminal "$2" ;;
  owns) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; owns "$2" ;;
  retire)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    FM_HOME=$2 STATE=${FM_STATE_OVERRIDE:-$2/state} DATA=${FM_DATA_OVERRIDE:-$2/data}
    retire "$3"
    ;;
  *) usage >&2; exit 2 ;;
esac
