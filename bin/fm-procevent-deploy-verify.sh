#!/usr/bin/env bash
# Built-in process-event adapter that spawns or steers a Tester for its verify asks.
#
# Usage:
#   fm-procevent-deploy-verify.sh arm
#   fm-procevent-deploy-verify.sh replay-skips [--dry-run]
#   fm-procevent-deploy-verify.sh deploy --dry-run --sha <sha> [--base <sha>]
#   fm-procevent-deploy-verify.sh ask-rows <task> [--dry-run]
#   fm-procevent-deploy-verify.sh wait
#   fm-procevent-deploy-verify.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-deploy-verify.sh classify <result-file>
#   fm-procevent-deploy-verify.sh silent <result-file>
#   fm-procevent-deploy-verify.sh terminal <result-file>
#   fm-procevent-deploy-verify.sh self-announcing
#   fm-procevent-deploy-verify.sh relisten
#
# arm          Register source `deploy-verify` with the runner (bin/fm-procevent.sh).
#              Run it once per home; reconcile keeps the poll alive.
# wait         The blocking child. It polls the project's main CI runs at most once
#              per FM_DEPLOY_VERIFY_POLL_SECONDS (default 60), in run order, past the
#              cursor in data/deploy-verify/state.json. A run whose "Deploy Development
#              host (5001)" job is green deploys its commits since the last green
#              deploy. The merged PRs of those commits map to tasks through state/*.meta
#              `pr=` and the backlog line's PR URL, and to an issue through the PR's
#              closing reference or the backlog line's `<repo> #n`. Open task PRs are
#              also checked for a new head whose issue has `(draft)` acceptance lines.
#              It prints one fm-deploy-verify-result.v1 JSON when there is an ask, a
#              skip to record, a first GitHub failure, or a recovery to clear.
#              A skipped, cancelled or failed deploy asks nothing; the next green
#              deploy carries its commits.
#              The first poll only sets the cursor to the newest finished run; it never
#              asks about history.
# autohandle   Deliver each ask to a Tester: a live Tester for the same task (its
#              state/<tester>.meta exists) gets the ask through bin/fm-send.sh,
#              otherwise a new scout `verify-<task>-<sha7>` is spawned from
#              config/roles/tester.md and config/roles/tester.json and the ask is
#              written into its brief. Each delivered ask is recorded in
#              data/deploy-verify/ledger.jsonl, then the cursor advances and the
#              result is acknowledged. One ask goes out per task per deploy, and a
#              PR already asked about is never asked again. A refused delivery or an
#              unreadable GitHub leaves the result unacknowledged, so the runner
#              publishes one wake; the next poll retries the same asks, and the same
#              reason stays quiet until a poll succeeds.
#              At most FM_DEPLOY_VERIFY_MAX_TESTERS (default 2) Testers may be live;
#              a further ask is held with a cap hold line and a task wait, and the
#              poll does not advance its cursor, so the ask is planned again next
#              poll. A live Tester is the last ledger ask line's `tester` whose
#              state/<tester>.meta still exists.
# replay-skips Re-read no-user-visible-line and template-refused skips included in
#              last_green_sha, so a corrected issue gets its ask.
#              Plan one deploy ask per task with key replay:<task>:<sha>.
#              --dry-run prints asks without sending or writing anything.
#              Replayed asks read the issue the same way as every other ask; an
#              issue the parser refuses is named on stderr and asks nothing.
#              User-visible no-issue, no-user-visible-line and template-refused skips
#              leave one result unacknowledged to wake firstmate; internal/no-task
#              stay quiet.
# deploy --dry-run
#              Plan the deploy of <sha> (the merged PRs since <base>, default the
#              cursor's last_green_sha) as the deploy round would, with the ledger
#              ignored, narrow each ask as below, and print {"asks": [...],
#              "skips": [...]}. It writes nothing: a task begun after T5 is read
#              with `checks <task> --as-deployed <sha> --touched <ids>`.
# ask-rows     Build and send the rows asks of one task now (see the rows round
#              below); --dry-run prints them before any env gate and writes nothing.
# Issues are read only through bin/fm-acceptance.mjs. Visible mode asks for the
# user-visible scenarios, draft mode for the scenarios on a draft page. Each ask
# carries `lines` (the scenario ids) and `rows` (the parser's `rows` output: one
# pending row per scenario and width), so the Tester starts its record from them.
# For a task begun after T5 ('record: rows' in data/<task>/verify.md) the task
# record first gets the issue's user-visible check rows and a deploy event naming
# the deployed head (a deploy round only), then the ask also carries `check`, the
# bin/fm-task.sh call that records each row's result; a refused record write
# fails the delivery, so the next poll retries it. FM_TASK_SHADOW_WRITER replaces
# bin/fm-task.sh, and config/task-shadow holds its settings.
# A deploy round asks only for the rows the Tester checks on the deployed head
# (firstmate#176 G2). Each merged PR names the scenarios it changes in one PR-body
# line `Scenarios touched: <ids>|none|all`; only an explicit `none` names none, and
# a PR with no line, or a line with neither ids nor `none`, touches all. A pass on
# an earlier deployed head carries while no PR of the deploy names its id: the ask
# drops that row, drops an id with no row left from `lines`, and lists the row under
# `carried` with the head it passed on. Only a task begun after T5 carries: it reads
# its rows with `checks <task>` after its deploy event, which records `--touched`. A
# task begun before T5 keeps the old path (no migration): nothing of it carries, and
# its ask holds every row. An ask with no row left is not sent; the ledger gets a
# carry line instead. A draft round and a replay ask are never narrowed.
# The rows round (firstmate#176 G4) asks the Tester from the record: each poll reads
# `checks <task>` for every task with state/<task>.meta and 'record: rows', and
# plans one ask per head for its user-visible rows that are pending with next actor
# tester on an explicit head (a worker's `check <task> <id>@<width> pending
# --next-actor tester --head <sha>`). A row already asked on that head is not asked
# again. The ask holds exactly those rows, `env` (each scenario's env text), and
# `envs`: for each config/env/<name> whose name the env text holds as `<name>` or
# "env <name>", the file's free-RAM read and floor, the recover step when it ran,
# and the processes never to touch. A config/env/<name> file holds lines
# `ram-read=<command printing the free RAM in GB>`, `floor-gb=<number>`, an optional
# `recover=<command>` and `never-touch=<process>, ...` (# starts a comment). Below
# the floor the builder runs the recover command once and reads again; still below,
# the ask is held: the record gets a wait naming the floor, the ledger a hold line,
# and the ask is planned again after FM_DEPLOY_VERIFY_HOLD_SECONDS (default 600).
# Each such env is also a lease `env:<name>` (bin/fm-lease.sh, G5): while another
# holder's lease is live the ask is held the same way, naming the holder, before any
# RAM read, and planned again at every poll; a sent ask claims the lease under the
# Tester's own id first. Every ask naming the lease since its last release holds it;
# each poll releases it once each row of every such ask has a result that is not
# pending, on that ask's head, and a failed send gives back only a lease no other ask
# holds. The poll also releases outstanding legacy `tester` leases by the same rule.
# Before a sent ask, the record gets a wait on the Tester that clears on those rows.
# An issue the parser refuses is a `template-refused` skip naming its problems; it
# wakes firstmate once like a visible skip below, and a refused draft round is only
# a draft-skip, because the deploy round of the same issue refuses and wakes.
# silent       Exit 0 when the result needs no firstmate action: no error and every
#              ask and skip is already in the ledger.
# self-announcing, relisten
#              Exit 0: a delivered ask is announced by the Tester inbox itself, and
#              the runner keeps polling after a fully handled result.
#
# Ledger lines (data/deploy-verify/ledger.jsonl):
#   {type:"ask", round:"deploy"|"draft", key, task, issue, prs, sha, run, lines, rows, touched?, carried?, check?, tester}
#   {type:"carry", round:"deploy", key, task, prs, sha, carried}
#   {type:"ask", round:"rows", key, task, issue, prs, sha, head, lines, rows, env, envs, check?, tester}
#   {type:"hold", round:"rows"|"deploy"|"draft", key, task, sha, envs, held, lease?, cap?}
#   {type:"release", lease, task, key}
#   {type:"skip", pr, task, reason:"no-task"|"internal"|"no-issue"|"no-user-visible-line"|"template-refused", detail?}
#   {type:"draft-skip", key, reason, detail?}
# Needs node (bin/fm-acceptance.mjs) and jq.
# Environment: FM_DEPLOY_VERIFY_REPO (default huynhtandat223/cfw-modules), _JOB,
# _WORKFLOW, _GH (the gh command), _POLL_SECONDS, _MAX_TESTERS (default 2),
# _SPAWN (bin/fm-spawn.sh), _TASKS (bin/fm-tasks-axi.sh), _BRIEF (bin/fm-brief.sh),
# _SEND (bin/fm-send.sh), _ONCE=1 (poll once and exit 1 when nothing is due).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="$FM_HOME/data/deploy-verify"
LEDGER="$DATA/ledger.jsonl"
CURSOR="$DATA/state.json"
LAST_ERROR="$DATA/last-error"
LAST_POLL="$DATA/last-poll"

REPO="${FM_DEPLOY_VERIFY_REPO:-huynhtandat223/cfw-modules}"
JOB="${FM_DEPLOY_VERIFY_JOB:-Deploy Development host (5001)}"
WORKFLOW="${FM_DEPLOY_VERIFY_WORKFLOW:-CI}"
GH="${FM_DEPLOY_VERIFY_GH:-gh}"
POLL_SECONDS="${FM_DEPLOY_VERIFY_POLL_SECONDS:-60}"
MAX_TESTERS="${FM_DEPLOY_VERIFY_MAX_TESTERS:-2}"
SPAWN_CMD="${FM_DEPLOY_VERIFY_SPAWN:-$SCRIPT_DIR/fm-spawn.sh}"
TASKS_CMD="${FM_DEPLOY_VERIFY_TASKS:-$SCRIPT_DIR/fm-tasks-axi.sh}"
BRIEF_CMD="${FM_DEPLOY_VERIFY_BRIEF:-$SCRIPT_DIR/fm-brief.sh}"
SEND_CMD="${FM_DEPLOY_VERIFY_SEND:-$SCRIPT_DIR/fm-send.sh}"
SOURCE_ID=deploy-verify

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-procevent-ask-lib.sh
. "$SCRIPT_DIR/fm-procevent-ask-lib.sh"

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

case "$MAX_TESTERS" in
  ''|*[!0-9]*) die 'FM_DEPLOY_VERIFY_MAX_TESTERS must be a positive integer' ;;
esac
[ "$MAX_TESTERS" -gt 0 ] || die 'FM_DEPLOY_VERIFY_MAX_TESTERS must be a positive integer'

READ_ERROR_FILE="$DATA/.read-error"
READ_ERROR=
ACCEPTANCE="$SCRIPT_DIR/fm-acceptance.mjs"

# ---- ledger and cursor (ledger_test, ledger_append: bin/fm-procevent-ask-lib.sh) ----

# shellcheck disable=SC2016 # jq variables, not shell
ledger_has_key() { ledger_test '(.type == "ask" or .type == "carry" or .type == "draft-skip") and .key == $k' --arg k "$1"; }
# shellcheck disable=SC2016 # jq variables, not shell
ledger_pr_final() {  # <pr-url> <task>: asked or carried in a deploy round, or skipped already
  [ "$PLAN_IGNORE_LEDGER" = 0 ] || return 1
  ledger_test '.task == $t and (((.type == "ask" or .type == "carry") and .round == "deploy" and (.prs | index($p))) or (.type == "skip" and .pr == $p))' \
    --arg p "$1" --arg t "$2"
}
PLAN_IGNORE_LEDGER=0

state_put() {  # <cursor-run> <last-green-sha>
  jq -cn --argjson r "$1" --arg s "$2" '{cursor_run: $r, last_green_sha: $s}' > "$CURSOR.tmp" \
    && mv -f "$CURSOR.tmp" "$CURSOR"
}

# ---- task and issue mapping ------------------------------------------------

# One |-separated row per PR and task: url, task, surface, issue hint, live (1 for a task
# that still has state/<task>.meta). Live rows come from the endpoint records,
# finished tasks from the PR URL on their backlog row (bin/fm-tasks-axi.sh rows).
build_map() {  # <out-file>
  local f pr task surface
  {
    for f in "$STATE"/*.meta; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      grep -qx 'kind=ship' "$f" || continue
      pr=$(sed -n 's/^pr=//p' "$f" | head -1)
      case "$pr" in "https://github.com/$REPO/pull/"[0-9]*) ;; *) continue ;; esac
      task=$(basename "$f" .meta)
      surface=$(sed -n 's/^surface=//p' "$f" | head -1)
      printf '%s|%s|%s||1\n' "$pr" "$task" "$surface"
    done
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" rows --kind ship --fields links 2>/dev/null \
      | jq -r --arg repo "$REPO" --arg short "${REPO##*/}" '
        .[] | .id as $task | ((((.title // "") | capture($short + " #(?<n>[0-9]+)")?) | .n) // null) as $hint
        | ("\(.title // "") \(.links // "")" | scan("https://github.com/" + $repo + "/pull/[0-9]+"))
        | "\(.)|\($task)||\($hint // "")|0"' || true
  } | awk -F'|' '
    { k = $1 FS $2; seen[k] = 1; if ($3 != "") s[k] = $3; if ($4 != "") h[k] = $4; if ($5 == 1) l[k] = 1 }
    END { for (k in seen) { split(k, a, FS); printf "%s|%s|%s|%s|%d\n", a[1], a[2], s[k], h[k], l[k] } }' \
    | sort > "$1"
}

resolve_issue() {  # <pr-body> <backlog-hint>: the issue number, or nothing
  local n
  n=$(printf '%s\n' "$1" | grep -oiE "(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed)|part of|refs?)[: ]+(${REPO}#|https://github.com/${REPO}/issues/|#)[0-9]+" \
    | grep -oE '[0-9]+$' | head -1)
  printf '%s\n' "${n:-$2}"
}

# Read an issue body through the one acceptance parser, bin/fm-acceptance.mjs.
# Sets ISSUE_LINES (scenario ids, one per line), ISSUE_ROWS (a JSON array of the
# parser's record rows), ISSUE_ENVS (a JSON object: scenario id -> env text) and ISSUE_PROBLEMS. Visible mode takes the user-visible
# scenarios, draft mode the scenarios on a draft page. Exit 0: read. Exit 1: the
# parser refused the issue. Exit 2: the parser did not run (READ_ERROR_FILE says so).
read_acceptance() {  # <visible|draft> <issue-body>
  local mode=$1 body=$2 parsed rows_out rc flag=
  ISSUE_LINES=
  ISSUE_ROWS='[]'
  ISSUE_ENVS='{}'
  ISSUE_PROBLEMS=
  parsed=$(printf '%s\n' "$body" | node "$ACCEPTANCE" parse - 2>/dev/null)
  rc=$?
  if ! jq -e '.schema == "fm-acceptance.v1"' <<<"$parsed" >/dev/null 2>&1; then
    printf 'acceptance parser could not run: node %s (exit %s)\n' "${ACCEPTANCE##*/}" "$rc" > "$READ_ERROR_FILE"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    ISSUE_PROBLEMS=$(jq -r '.problems | join("; ")' <<<"$parsed")
    return 1
  fi
  [ "$mode" != draft ] || flag=--draft
  # shellcheck disable=SC2086 # flag is one word or nothing
  rows_out=$(printf '%s\n' "$body" | node "$ACCEPTANCE" rows - $flag 2>/dev/null) || {
    printf 'acceptance parser could not run: node %s rows (exit %s)\n' "${ACCEPTANCE##*/}" "$?" > "$READ_ERROR_FILE"
    return 2
  }
  ISSUE_ROWS=$(printf '%s' "$rows_out" | jq -R . | jq -sc 'map(select(. != ""))')
  ISSUE_LINES=$(jq -r --arg m "$mode" '.scenarios[] | select(if $m == "draft" then .draft else .surface == "user-visible" end) | .id' <<<"$parsed")
  ISSUE_ENVS=$(jq -c '[.scenarios[] | {key: .id, value: (.env // "")}] | from_entries' <<<"$parsed")
}

# ---- planning --------------------------------------------------------------

ASKS='[]'
SKIPS='[]'
add_ask() { ASKS=$(jq -c --argjson a "$1" '. + [$a]' <<<"$ASKS"); }
add_skip() {  # <pr> <task> <reason> <sha> [issue] [detail]
  SKIPS=$(jq -c --arg pr "$1" --arg t "$2" --arg r "$3" --arg s "$4" --arg i "${5:-}" --arg d "${6:-}" \
    '. + [{pr: $pr, task: $t, reason: $r, sha: $s, issue: $i} + (if $d == "" then {} else {detail: $d} end)]' <<<"$SKIPS")
}

attention_skip() {
  jq -e 'any(.skips[]; .task != "" and (.reason == "no-user-visible-line" or .reason == "no-issue" or .reason == "template-refused"))' "$1" >/dev/null 2>&1
}

# The catch-up acknowledgement in fm-procevent-ask-lib.sh leaves an older result
# with a visible skip pending: it was left unhandled so one wake reaches firstmate.
keep_pending_result() { attention_skip "$1"; }

issue_ref() {
  case "$1" in task:*) printf '%s\n' "${1#task:}" ;; *) printf '%s#%s\n' "${REPO##*/}" "$1" ;; esac
}

acceptance_url() (
  # shellcheck source=bin/fm-task-shadow-config-lib.sh
  . "$SCRIPT_DIR/fm-task-shadow-config-lib.sh"
  fm_task_shadow_config "$CONFIG/task-shadow"
  case "$1" in task:*) printf '%s/#firstmate.board?view=board&task=%s\n' "${FM_TASK_BASE_URL:-http://127.0.0.1:5001}" "${1#task:}" ;; https://github.com/*) printf '%s\n' "$1" ;; *) printf 'https://github.com/%s/issues/%s\n' "$REPO" "$1" ;; esac
)

recorded_acceptance() {  # <task> <pr-body> <hint>
  local source
  source=$(sed -n 's/^issue: //p' "$FM_HOME/data/$1/verify.md" 2>/dev/null | tail -n 1)
  case "$source" in
    task:*) printf '%s\n' "$source" ;;
    https://github.com/*/*/issues/[0-9]*)
      if [[ "$source" == "https://github.com/$REPO/issues/"* ]]; then printf '%s\n' "${source##*/}"; else printf '%s\n' "$source"; fi ;;
    *) resolve_issue "$2" "$3" ;;
  esac
}

acceptance_body_json() {
  case "$1" in
    task:*)
      local content
      content=$(task_writer document "${1#task:}") || return 1
      jq -cn --arg body "$content" '{body:$body}'
      ;;
    https://github.com/*/*/issues/[0-9]*) gh_read "repos/${1#https://github.com/}" ;;
    *) gh_read "repos/$REPO/issues/$1" ;;
  esac
}

# The PR body's `Scenarios touched:` line: all, none, or its ids, comma-separated. Only an explicit `none` names none;
# a body with no line, or a line with neither ids nor `none`, touches all, so its deploy carries nothing.
pr_touched() {  # <pr-body>
  printf '%s\n' "$1" | tr -d '\r`' | awk '
    tolower($0) ~ /^[ \t]*([-*][ \t]*)?scenarios touched:/ {
      sub(/^[^:]*:/, ""); gsub(/[ \t,;]+/, " ")
      n = split($0, ids, " "); o = ""; z = 0
      for (i = 1; i <= n; i++) {
        id = ids[i]; sub(/\.$/, "", id); t = tolower(id)
        if (t == "all") { print "all"; found = 1; exit }
        if (t == "none") z = 1
        else if (id ~ /^[A-Za-z0-9_.-]+$/) o = o (o == "" ? "" : ",") id
      }
      print (o != "" ? o : (z ? "none" : "all")); found = 1; exit
    }
    END { if (!found) print "all" }'
}

# Plan the deploy of <sha>: every merged PR in the commits since <base> maps to
# its tasks. A PR already asked about or skipped for a task is left alone.
plan_deploy() {  # <base-sha> <sha> <run-url> <completed-at> <workdir>
  local base=$1 sha=$2 run=$3 completed=$4 w=$5 commits c pulls
  local url body task surface hint issue n rows tasks arrival issue_json lines touched
  : > "$w/prs.jsonl"
  if [ -n "$base" ] && [ "$base" != "$sha" ]; then
    pulls=$(gh_read "repos/$REPO/compare/$base...$sha") || return 1
    commits=$(jq -r '.commits[].sha' <<<"$pulls")
  elif [ -z "$base" ]; then
    commits=$sha
  else
    commits=
  fi
  for c in $commits; do
    pulls=$(gh_read "repos/$REPO/commits/$c/pulls") || return 1
    jq -c '.[] | select(.merged_at != null and .base.ref == "main") | {url: .html_url, body: (.body // "")}' <<<"$pulls" >> "$w/prs.jsonl"
  done
  : > "$w/rows.psv"
  while IFS= read -r pr_json; do
    url=$(jq -r .url <<<"$pr_json")
    body=$(jq -r .body <<<"$pr_json")
    if ! awk -F'|' -v p="$url" '$1 == p { f = 1 } END { exit !f }' "$w/map.psv"; then
      ledger_pr_final "$url" "" || add_skip "$url" "" no-task "$sha"
      continue
    fi
    while IFS='|' read -r _ task surface hint _; do
      ledger_pr_final "$url" "$task" && continue
      issue=$(recorded_acceptance "$task" "$body" "$hint")
      if [ -z "$issue" ] && printf '%s\n' "$body" | grep -qE '^Task: '; then issue="task:$task"; fi
      printf '%s|%s|%s|%s|%s\n' "$task" "$surface" "$url" "$issue" "$(pr_touched "$body")" >> "$w/rows.psv"
    done < <(awk -F'|' -v p="$url" '$1 == p' "$w/map.psv")
  done < <(jq -sc 'unique_by(.url) | .[]' "$w/prs.jsonl")
  tasks=$(cut -d'|' -f1 "$w/rows.psv" | sort -u)
  for task in $tasks; do
    rows=$(awk -F'|' -v t="$task" '$1 == t' "$w/rows.psv")
    surface=$(printf '%s\n' "$rows" | head -1 | cut -d'|' -f2)
    if [ "$surface" = internal ]; then
      while IFS='|' read -r _ _ url _; do add_skip "$url" "$task" internal "$sha"; done <<<"$rows"
      continue
    fi
    n=$(printf '%s\n' "$rows" | cut -d'|' -f4 | grep -m1 . || true)
    if [ -z "$n" ]; then
      while IFS='|' read -r _ _ url _; do add_skip "$url" "$task" no-issue "$sha"; done <<<"$rows"
      continue
    fi
    issue_json=$(acceptance_body_json "$n") || return 1
    read_acceptance visible "$(jq -r '.body // ""' <<<"$issue_json")"
    case $? in
      0) ;;
      1)
        while IFS='|' read -r _ _ url _; do add_skip "$url" "$task" template-refused "$sha" "$(issue_ref "$n")" "$ISSUE_PROBLEMS"; done <<<"$rows"
        continue
        ;;
      *) return 1 ;;
    esac
    lines=$ISSUE_LINES
    if [ -z "$lines" ]; then
      while IFS='|' read -r _ _ url _; do add_skip "$url" "$task" no-user-visible-line "$sha" "$(issue_ref "$n")"; done <<<"$rows"
      continue
    fi
    arrival=$(jq -n --arg d "$completed" '$d | fromdateiso8601')
    # The scenarios the task's PRs in this deploy touch: all when one PR says all, else the union of their ids.
    touched=$(printf '%s\n' "$rows" | cut -d'|' -f5 | awk -F, '
      $0 == "all" { a = 1 }
      $0 != "all" && $0 != "none" { for (i = 1; i <= NF; i++) if (!s[$i]++) o = o (o == "" ? "" : ",") $i }
      END { print a ? "all" : (o == "" ? "none" : o) }')
    add_ask "$(jq -cn --arg key "deploy:$task:$sha" --arg task "$task" --arg issue "$(issue_ref "$n")" \
      --arg issue_url "$(acceptance_url "$n")" --arg sha "$sha" --arg run "$run" --argjson arrival "$arrival" \
      --argjson prs "$(printf '%s\n' "$rows" | cut -d'|' -f3 | jq -R . | jq -sc .)" \
      --argjson lines "$(printf '%s\n' "$lines" | jq -R . | jq -sc .)" --argjson rows "$ISSUE_ROWS" --arg touched "$touched" \
      '{round: "deploy", key: $key, task: $task, issue: $issue, issue_url: $issue_url, prs: $prs, sha: $sha, run: $run, lines: $lines, rows: $rows, touched: $touched, arrival: $arrival}')"
  done
}

# Ask for the draft lines of each open task PR whose head is new.
plan_drafts() {  # <workdir>
  local w=$1 url task surface hint n pr head key issue body issue_json lines commit pushed arrival
  while IFS='|' read -r url task surface hint live; do
    [ "$live" = 1 ] || continue
    n=${url##*/}
    pr=$(gh_read "repos/$REPO/pulls/$n") || return 1
    [ "$(jq -r .state <<<"$pr")" = open ] || continue
    head=$(jq -r .head.sha <<<"$pr")
    key="draft:$task:$n:$head"
    ledger_has_key "$key" && continue
    if [ "$surface" = internal ]; then
      ledger_append "$(jq -cn --arg k "$key" '{type: "draft-skip", key: $k, reason: "internal"}')"
      continue
    fi
    body=$(jq -r '.body // ""' <<<"$pr")
    issue=$(recorded_acceptance "$task" "$body" "$hint")
    if [ -z "$issue" ] && printf '%s\n' "$body" | grep -qE '^Task: '; then issue="task:$task"; fi
    if [ -z "$issue" ]; then
      ledger_append "$(jq -cn --arg k "$key" '{type: "draft-skip", key: $k, reason: "no-issue"}')"
      continue
    fi
    issue_json=$(acceptance_body_json "$issue") || return 1
    read_acceptance draft "$(jq -r '.body // ""' <<<"$issue_json")"
    case $? in
      0) ;;
      1)
        ledger_append "$(jq -cn --arg k "$key" --arg d "$ISSUE_PROBLEMS" '{type: "draft-skip", key: $k, reason: "template-refused", detail: $d}')"
        continue
        ;;
      *) return 1 ;;
    esac
    lines=$ISSUE_LINES
    if [ -z "$lines" ]; then
      ledger_append "$(jq -cn --arg k "$key" '{type: "draft-skip", key: $k, reason: "no-draft-lines"}')"
      continue
    fi
    commit=$(gh_read "repos/$REPO/commits/$head") || return 1
    pushed=$(jq -r '.commit.committer.date' <<<"$commit")
    arrival=$(jq -n --arg d "$pushed" '$d | fromdateiso8601')
    add_ask "$(jq -cn --arg key "$key" --arg task "$task" --arg issue "$(issue_ref "$issue")" \
      --arg issue_url "$(acceptance_url "$issue")" --arg head "$head" --arg pushed "$pushed" \
      --arg pr "$url" --argjson arrival "$arrival" \
      --argjson lines "$(printf '%s\n' "$lines" | jq -R . | jq -sc .)" --argjson rows "$ISSUE_ROWS" \
      '{round: "draft", key: $key, task: $task, issue: $issue, issue_url: $issue_url, prs: [$pr], sha: $head, head: $head, pushed: $pushed, run: null, lines: $lines, rows: $rows, arrival: $arrival}')"
  done < "$w/map.psv"
}

# The rows asks of one task begun after T5 (see the header): one per head of its rows pending for the Tester on an
# explicit head, without the rows already asked on that head, and without a held ask until its hold is old enough.
# Returns 1 with READ_ERROR_FILE set when the record or GitHub cannot be read.
plan_rows_task() {  # <task>
  local task=$1 json issue_url repo n ref issue_json head keys key rows lines held_at now description
  json=$(task_writer checks "$task" 2>&1)
  # shellcheck disable=SC2181 # the status of the assignment above
  if [ "$?" -ne 0 ] || ! jq -e '.rows | type == "array"' <<<"$json" >/dev/null 2>&1; then
    printf 'the task record of %s could not be read: %s\n' "$task" "$(printf '%s' "$json" | sed -n '1p')" > "$READ_ERROR_FILE"
    return 1
  fi
  jq -e 'any(.rows[]; .surface == "user-visible" and .status == "pending" and .nextActor == "tester" and .head != null)' <<<"$json" >/dev/null || return 0
  issue_url=$(jq -r '.issueUrl // empty' <<<"$json")
  if [ "$issue_url" = "$task" ]; then
    description=$(task_writer document "$task") || return 1
    if printf '%s\n' "$description" | node "$ACCEPTANCE" parse - 2>/dev/null | jq -e '.scenarios | length > 0' >/dev/null; then
      issue_url="task:$task"
    else
      issue_url=''
    fi
  fi
  [ -n "$issue_url" ] || issue_url=$(sed -n 's/^issue: //p' "$FM_HOME/data/$task/verify.md" | tail -n 1)
  if [ -z "$issue_url" ] || [[ "$issue_url" == task:* || "$issue_url" == *'#firstmate.board?'*'task='* ]]; then
    case "$issue_url" in task:*) n=$issue_url ;; *) n="task:$task" ;; esac
    issue_url=$(acceptance_url "$n")
    ref=$(issue_ref "$n")
    issue_json=$(acceptance_body_json "$n") || return 1
  else
    case "$issue_url" in https://github.com/*/*/issues/[0-9]*) ;; *) return 0 ;; esac
    repo=${issue_url#https://github.com/}
    repo=${repo%/issues/*}
    n=${issue_url##*/}
    ref="${repo##*/}#$n"
    issue_json=$(gh_read "repos/$repo/issues/$n") || return 1
  fi
  read_acceptance visible "$(jq -r '.body // ""' <<<"$issue_json")"
  case $? in 0) ;; 1) return 0 ;; *) return 1 ;; esac
  now=$(date +%s)
  while IFS= read -r head; do
    [ -n "$head" ] || continue
    # shellcheck disable=SC2016 # jq variables, not shell
    keys=$(comm -23 \
      <(jq -r --arg h "$head" '.rows[] | select(.surface == "user-visible" and .status == "pending" and .nextActor == "tester" and .head == $h) | .key' <<<"$json" | sort -u) \
      <([ ! -f "$LEDGER" ] || jq -Rr --arg t "$task" --arg h "$head" 'fromjson? | select(.type == "ask" and .task == $t and .sha == $h) | .rows[] | ltrimstr("- ") | split(" | ")[0]' "$LEDGER" | sort -u))
    [ -n "$keys" ] || continue
    rows=$(jq -c --argjson k "$(printf '%s\n' "$keys" | jq -R . | jq -sc .)" 'map(select((ltrimstr("- ") | split(" | ")[0]) as $r | $k | index($r)))' <<<"$ISSUE_ROWS")
    [ "$rows" != '[]' ] || continue
    lines=$(jq -c 'reduce (.[] | ltrimstr("- ") | split(" | ")[0] | split("@")[0]) as $i ([]; if index([$i]) then . else . + [$i] end)' <<<"$rows")
    key="rows:$task:$head:$(jq -r '.[]' <<<"$rows" | sha256sum | cut -c1-12)"
    # shellcheck disable=SC2016 # jq variables, not shell
    held_at=$([ ! -f "$LEDGER" ] || jq -Rr --arg k "$key" 'fromjson? | select(.type == "hold" and .key == $k and (.lease | not) and (.cap | not)) | .at' "$LEDGER" | tail -n 1)
    [ -z "$held_at" ] || [ $((now - held_at)) -ge "${FM_DEPLOY_VERIFY_HOLD_SECONDS:-600}" ] || continue
    add_ask "$(jq -cn --arg key "$key" --arg task "$task" --arg issue "$ref" --arg issue_url "$issue_url" --arg head "$head" \
      --argjson rows "$rows" --argjson lines "$lines" --argjson envs "$ISSUE_ENVS" --argjson arrival "$now" \
      '{round: "rows", key: $key, task: $task, issue: $issue, issue_url: $issue_url, prs: [], sha: $head, head: $head, run: null,
        lines: $lines, rows: $rows, env: ($envs | with_entries(select(.key as $id | $lines | index($id)))), arrival: $arrival}')"
  done < <(jq -r '[.rows[] | select(.surface == "user-visible" and .status == "pending" and .nextActor == "tester" and .head != null) | .head] | unique[]' <<<"$json")
}

# The rows asks of every live task begun after T5.
plan_rows() {
  local f task
  for f in "$STATE"/*.meta; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    task=$(basename "$f" .meta)
    rows_task "$task" || continue
    plan_rows_task "$task" || return 1
  done
}

env_lease() {  # <fm-lease.sh args>...
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-lease.sh" "$@"
}

# The asks that hold the Tester's lease <env:name>: a JSON array of the ledger's ask lines naming it after its last
# release line. A later claim by the Tester refreshes the same lease, so every one of them holds it.
lease_asks() {  # <env:name>
  [ -f "$LEDGER" ] || { printf '[]\n'; return 0; }
  # shellcheck disable=SC2016 # jq variables, not shell
  jq -Rsc --arg l "$1" '[split("\n")[] | fromjson? | objects] as $all
    | ([range(0; $all | length) | select($all[.].type == "release" and $all[.].lease == $l)] | last // -1) as $r
    | [$all[$r + 1:][] | select(.type == "ask" and ((.leases // []) | index($l)))]' "$LEDGER"
}

# The Tester's env lease ends when every ask that holds it (lease_asks) has a result that is not pending, on the ask's
# own head, on each of its rows.
release_landed_leases() {
  local f name asks ask task json landed holder
  for f in "$STATE"/.envlease-*; do
    [ -e "$f" ] && [ -f "$LEDGER" ] || continue
    name=${f##*/.envlease-}
    holder=$(cut -f1 "$f" 2>/dev/null)
    case "$holder" in tester|verify-*) ;; *) continue ;; esac
    asks=$(lease_asks "env:$name")
    [ "$(jq length <<<"$asks")" -gt 0 ] || continue
    landed=1
    while IFS= read -r ask; do
      task=$(jq -r .task <<<"$ask")
      json=$(task_writer checks "$task" 2>/dev/null) || { landed=0; break; }
      # shellcheck disable=SC2016 # jq variables, not shell
      jq -e --argjson k "$(jq -c '[.rows[] | ltrimstr("- ") | split(" | ")[0]]' <<<"$ask")" --arg h "$(jq -r '.head // .sha' <<<"$ask")" \
        '(.rows | type == "array") and all(.rows[] | select(.key as $r | $k | index($r)); .status != "pending" and .head == $h)' <<<"$json" >/dev/null 2>&1 \
        || { landed=0; break; }
    done < <(jq -c '.[]' <<<"$asks")
    [ "$landed" = 1 ] || continue
    env_lease release "env:$name" --holder "$holder" >/dev/null 2>&1 || continue
    ledger_append "$(jq -c --arg l "env:$name" --argjson at "$(date +%s)" \
      'last as $n | {type: "release", lease: $l, task: $n.task, key: $n.key, tasks: (map(.task) | unique), keys: map(.key), at: $at}' <<<"$asks")"
  done
}

CURSOR_RUN=
CURSOR_SHA=
# One poll. Exit 0: a result is ready in ASKS, SKIPS and the cursor variables.
# Exit 1: nothing is due. Exit 2: GitHub could not be read (READ_ERROR).
poll_once() {
  local w runs baseline run_id sha status run_url completed jobs conclusion cursor_run base
  ASKS='[]'
  SKIPS='[]'
  CURSOR_RUN=
  CURSOR_SHA=
  w=$(mktemp -d "${TMPDIR:-/tmp}/fm-deploy-verify.XXXXXX") || return 2
  build_map "$w/map.psv"
  runs=$(gh_read "repos/$REPO/actions/runs?branch=main&event=push&per_page=30") || { rm -rf "$w"; return 2; }
  runs=$(jq -c --arg wf "$WORKFLOW" '[.workflow_runs[] | select(.name == $wf)] | sort_by(.id)' <<<"$runs")
  if [ ! -s "$CURSOR" ]; then
    # First poll: start after the newest finished run, never backfill history.
    baseline=$(jq -c '[.[] | select(.status == "completed")] | last // empty' <<<"$runs")
    [ -z "$baseline" ] || state_put "$(jq -r .id <<<"$baseline")" "$(jq -r .head_sha <<<"$baseline")"
    rm -rf "$w"
    return 1
  fi
  cursor_run=$(jq -r .cursor_run "$CURSOR")
  base=$(jq -r '.last_green_sha // ""' "$CURSOR")
  CURSOR_RUN=$cursor_run
  CURSOR_SHA=$base
  while IFS= read -r run; do
    status=$(jq -r .status <<<"$run")
    [ "$status" = completed ] || break
    run_id=$(jq -r .id <<<"$run")
    sha=$(jq -r .head_sha <<<"$run")
    run_url=$(jq -r .html_url <<<"$run")
    jobs=$(gh_read "repos/$REPO/actions/runs/$run_id/jobs?per_page=100") || { rm -rf "$w"; return 2; }
    conclusion=$(jq -r --arg j "$JOB" '[.jobs[] | select(.name == $j)] | first | .conclusion // ""' <<<"$jobs")
    if [ "$conclusion" = success ]; then
      completed=$(jq -r --arg j "$JOB" '[.jobs[] | select(.name == $j)] | first | .completed_at' <<<"$jobs")
      plan_deploy "$base" "$sha" "$run_url" "$completed" "$w" || { rm -rf "$w"; return 2; }
      CURSOR_RUN=$run_id
      CURSOR_SHA=$sha
      if [ "$ASKS" != '[]' ] || [ "$SKIPS" != '[]' ]; then
        break
      fi
      base=$sha
    else
      CURSOR_RUN=$run_id
    fi
  done < <(jq -c --argjson c "$cursor_run" '.[] | select(.id > $c)' <<<"$runs")
  if [ "$ASKS" = '[]' ] && [ "$SKIPS" = '[]' ]; then
    [ "$CURSOR_RUN" = "$cursor_run" ] && [ "$CURSOR_SHA" = "$(jq -r '.last_green_sha // ""' "$CURSOR")" ] \
      || state_put "$CURSOR_RUN" "$CURSOR_SHA"
  fi
  plan_drafts "$w" || { rm -rf "$w"; return 2; }
  release_landed_leases
  plan_rows || { rm -rf "$w"; return 2; }
  rm -rf "$w"
  [ "$ASKS" != '[]' ] || [ "$SKIPS" != '[]' ]
}

# Replay only historical skips contained in the deployed history. Do not use
# ledger_pr_final here: the historical skip itself is what we are repairing.
cmd_replay_skips() {
  local dry=0 sha w row pr task body hint issue comparison merged lines rows n ask rc=0
  case "${1:-}" in --dry-run) dry=1; shift ;; esac
  [ "$#" -eq 0 ] || die 'usage: replay-skips [--dry-run]'
  sha=$(jq -er '.last_green_sha | select(length > 0)' "$CURSOR") || return 1
  [ -f "$LEDGER" ] || return 0
  w=$(mktemp -d "${TMPDIR:-/tmp}/fm-deploy-replay.XXXXXX") || return 1
  build_map "$w/map.psv"
  : > "$w/rows"
  while IFS= read -r row; do
    pr=$(jq -r .pr <<<"$row"); task=$(jq -r .task <<<"$row")
    [ -n "$task" ] || continue
    ledger_has_key "replay:$task:$sha" && continue
    # shellcheck disable=SC2016 # jq variables
    ledger_test '.type == "ask" and .round == "deploy" and .task == $t and (.prs | index($p))' --arg p "$pr" --arg t "$task" && continue
    body=$(gh_read "repos/$REPO/pulls/${pr##*/}") || { rc=1; break; }
    merged=$(jq -r '.merge_commit_sha // empty' <<<"$body")
    [ -n "$merged" ] || continue
    comparison=$(gh_read "repos/$REPO/compare/$merged...$sha") || { rc=1; break; }
    jq -e '.status == "ahead" or .status == "identical"' <<<"$comparison" >/dev/null || continue
    hint=$(awk -F'|' -v p="$pr" -v t="$task" '$1 == p && $2 == t {print $4; exit}' "$w/map.psv")
    issue=$(recorded_acceptance "$task" "$(jq -r '.body // ""' <<<"$body")" "$hint")
    if [ -z "$issue" ] && jq -er '.body // ""' <<<"$body" | grep -qE '^Task: '; then issue="task:$task"; fi
    printf '%s|%s|%s\n' "$task" "$pr" "$issue" >> "$w/rows"
  done < <(jq -sc 'unique_by([.task,.pr])[] | select(.type == "skip" and (.reason == "no-user-visible-line" or .reason == "template-refused"))' "$LEDGER")
  if [ "$rc" -eq 0 ]; then
    while IFS= read -r task; do
      rows=$(sort -u "$w/rows" | awk -F'|' -v t="$task" '$1 == t')
      n=$(cut -d'|' -f3 <<<"$rows" | grep -m1 . || true)
      [ -n "$n" ] || continue
      body=$(acceptance_body_json "$n") || { rc=1; break; }
      read_acceptance visible "$(jq -r '.body // ""' <<<"$body")"
      case $? in
        0) ;;
        1) printf 'refused: %s %s: %s\n' "$task" "$(issue_ref "$n")" "$ISSUE_PROBLEMS" >&2; continue ;;
        *) rc=1; break ;;
      esac
      lines=$ISSUE_LINES
      [ -n "$lines" ] || continue
      ask=$(jq -cn --arg key "replay:$task:$sha" --arg task "$task" --arg issue "$(issue_ref "$n")" \
        --arg url "$(acceptance_url "$n")" --arg sha "$sha" --argjson at "$(date +%s)" \
        --argjson prs "$(cut -d'|' -f2 <<<"$rows" | jq -R . | jq -sc .)" \
        --argjson lines "$(printf '%s\n' "$lines" | jq -R . | jq -sc .)" --argjson rows "$ISSUE_ROWS" \
        '{round:"deploy", key:$key, task:$task, issue:$issue, issue_url:$url, prs:$prs, sha:$sha, run:null, lines:$lines, rows:$rows, arrival:$at}')
      if [ "$dry" -eq 1 ]; then printf '%s\n' "$ask"; else
        deliver_ask "$ask" || { rc=1; break; }
        printf '%s\n' "$ask"
      fi
    done < <(cut -d'|' -f1 "$w/rows" | sort -u)
  fi
  rm -rf "$w"
  return "$rc"
}

# ---- wait ------------------------------------------------------------------

emit_result() {  # <error-or-empty> <recovered 0|1>
  jq -cn --arg error "$1" --argjson recovered "$2" --argjson asks "$ASKS" --argjson skips "$SKIPS" \
    --arg run "$CURSOR_RUN" --arg sha "$CURSOR_SHA" '
    {schema: "fm-deploy-verify-result.v1", asks: $asks, skips: $skips, recovered: ($recovered == 1),
     error: (if $error == "" then null else $error end),
     cursor: (if $run == "" or ($asks | length) + ($skips | length) == 0 then null else {cursor_run: ($run | tonumber), last_green_sha: $sha} end)}'
}

cmd_wait() {
  local rc previous
  command -v jq >/dev/null 2>&1 || die 'jq is required'
  command -v node >/dev/null 2>&1 || die 'node is required'
  mkdir -p "$DATA"
  while :; do
    throttle
    date +%s > "$LAST_POLL"
    poll_once
    rc=$?
    previous=
    [ ! -f "$LAST_ERROR" ] || previous=$(<"$LAST_ERROR")
    case "$rc" in
      0)
        emit_result '' 0
        return 0
        ;;
      2)
        # A failure is announced once; the same reason stays quiet while the
        # polls go on, and a poll that succeeds clears it below.
        READ_ERROR=$(<"$READ_ERROR_FILE")
        if [ "$previous" != "$READ_ERROR" ]; then
          printf '%s\n' "$READ_ERROR" > "$LAST_ERROR"
          ASKS='[]'
          SKIPS='[]'
          emit_result "$READ_ERROR" 0
          return 0
        fi
        ;;
      *)
        if [ -n "$previous" ]; then
          ASKS='[]'
          SKIPS='[]'
          emit_result '' 1
          return 0
        fi
        ;;
    esac
    [ "${FM_DEPLOY_VERIFY_ONCE:-0}" != 1 ] || return 1
  done
}

# ---- delivery --------------------------------------------------------------

# bin/fm-task.sh (FM_TASK_SHADOW_WRITER replaces it) with the settings of config/task-shadow, bounded to 120 s.
task_writer() {  # <args>...
  local -a writer=("${FM_TASK_SHADOW_WRITER:-$SCRIPT_DIR/fm-task.sh}")
  ! command -v timeout >/dev/null 2>&1 || writer=(timeout 120 "${writer[@]}")
  (
    # shellcheck source=bin/fm-task-shadow-config-lib.sh
    . "$SCRIPT_DIR/fm-task-shadow-config-lib.sh"
    fm_task_shadow_config "$CONFIG/task-shadow"
    "${writer[@]}" "$@" </dev/null
  )
}

rows_task() { grep -qx 'record: rows' "$FM_HOME/data/$1/verify.md" 2>/dev/null; }

# ---- Tester delivery -------------------------------------------------------

# A new Tester's task id: the task, then the first 7 characters of the deployed head.
tester_id_for_ask() {  # <ask-json>
  local task sha base id n=1 item
  task=$(jq -r .task <<<"$1")
  sha=$(jq -r '.head // .sha // ""' <<<"$1")
  base="verify-$task-${sha:0:7}"
  id=$base
  while :; do
    [ ! -f "$STATE/$id.meta" ] || { printf '%s\n' "$id"; return; }
    item=$(FM_HOME=$FM_HOME "$TASKS_CMD" show "$id" 2>/dev/null) || item=
    # shellcheck disable=SC2016 # jq variable
    if ! ledger_test '.type == "ask" and .tester == $id' --arg id "$id" \
      && ! grep -Eq '^  state: (done|archived|closed)' <<<"$item"; then
      printf '%s\n' "$id"
      return
    fi
    n=$((n + 1))
    id="$base-$n"
  done
}

# The live Tester of a task: the last ledger ask line's `tester` whose task record still exists.
tester_for_task() {  # <task> <ask-json>
  local id
  id=$(tester_id_for_ask "$2")
  if [ -f "$STATE/$id.meta" ]; then
    printf '%s\n' "$id"
    return
  fi
  [ -f "$LEDGER" ] || return 1
  # shellcheck disable=SC2016 # jq variables, not shell
  id=$(jq -Rr --arg t "$1" 'fromjson? | select(.type == "ask" and .task == $t and (.tester // "") != "") | .tester' "$LEDGER" | tail -n 1)
  [ -n "$id" ] && [ -f "$STATE/$id.meta" ] || return 1
  printf '%s\n' "$id"
}

# Live Testers, by scout task records the spawn leaves behind.
live_tester_count() {
  local f n=0
  for f in "$STATE"/verify-*.meta; do
    [ -f "$f" ] && [ ! -L "$f" ] && grep -qx 'kind=scout' "$f" && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Hold an ask for a new Tester when the cap is reached: a task wait naming the cap and one ledger
# hold line, and DELIVER_HELD tells the poll not to advance its cursor, so the ask is planned again.
DELIVER_HELD=0
hold_for_cap() {  # <ask-json>
  local reason
  reason="live Tester cap $MAX_TESTERS reached"
  if rows_task "$(jq -r .task <<<"$1")"; then
    rows_wait "$1" cap "Tester ask held, not sent: $reason" || return 1
  fi
  # shellcheck disable=SC2016 # jq variables
  if ! ledger_test '.type == "hold" and .key == $k and .cap == $cap' --arg k "$(jq -r .key <<<"$1")" --argjson cap "$MAX_TESTERS"; then
    ledger_append "$(jq -c --arg h "$reason" --argjson cap "$MAX_TESTERS" --argjson at "$(date +%s)" \
      '{type: "hold", round, key, task, sha, held: $h, cap: $cap, at: $at}' <<<"$1")"
  fi
  DELIVER_HELD=1
}

# Fill a scaffolded brief's two subsections from files, one section at a time.
# The spec replaces the scaffold's {FIRSTMATE_SPEC} placeholder line.
fill_brief() {  # <brief> <intent-file> <spec-file>
  local brief=$1 intent=$2 spec=$3 tmp
  tmp="$brief.fill"
  awk -v intent="$intent" -v spec="$spec" '
    function emit(file,    line) { while ((getline line < file) > 0) print line; close(file) }
    /^## Captain.s intent$/ { print; print ""; emit(intent); skip = 1; next }
    /^## Firstmate spec$/ { skip = 0; print; print ""; emit(spec); next }
    /^\{FIRSTMATE_SPEC\}$/ { next }
    skip { next }
    { print }
  ' "$brief" > "$tmp" && mv -f "$tmp" "$brief"
}

# The ask JSON a filled brief carries under `### The ask`, or nothing.
brief_ask() {  # <brief>
  awk '/^### The ask$/{f=1;next} f && /^```json$/{j=1;next} j && /^```$/{exit} j{print}' "$1"
}

# Spawn a new Tester scout for an ask and write the ask into its brief. Returns 1 with DELIVER_ERROR
# set when the role files, the backlog item, the brief, or the spawn is refused.
spawn_tester() {  # <ask-json> <content-json>
  local ask=$1 content=$2 id task sha issue_url role_md role_json harness model effort
  local tester_home record brief evidence intent spec
  local -a args=()
  id=$TESTER_ID
  task=$(jq -r .task <<<"$ask")
  sha=$(jq -r '.head // .sha' <<<"$ask")
  issue_url=$(jq -r .issue_url <<<"$ask")
  role_md="$CONFIG/roles/tester.md"
  role_json="$CONFIG/roles/tester.json"
  if [ ! -f "$role_md" ] || [ ! -f "$role_json" ]; then
    DELIVER_ERROR="Tester ask not delivered: the Tester template or pin is missing ($role_md, $role_json)"
    return 1
  fi
  harness=$(jq -r '.harness // ""' "$role_json" 2>/dev/null) || harness=
  if [ -z "$harness" ]; then
    DELIVER_ERROR="Tester ask not delivered: $role_json names no harness"
    return 1
  fi
  model=$(jq -r '.model // ""' "$role_json" 2>/dev/null) || model=
  effort=$(jq -r '.effort // ""' "$role_json" 2>/dev/null) || effort=
  if ! FM_HOME=$FM_HOME "$TASKS_CMD" show "$id" >/dev/null 2>&1; then
    if ! FM_HOME=$FM_HOME "$TASKS_CMD" add "$id" "Verify $task on $sha for $issue_url" --kind scout >/dev/null 2>&1; then
      DELIVER_ERROR="Tester ask not delivered: the backlog item $id could not be filed"
      return 1
    fi
  fi
  evidence="$FM_HOME/data/verify/$task/$id"
  if ! mkdir -p "$evidence"; then
    DELIVER_ERROR="Tester ask not delivered: the evidence directory $evidence could not be created"
    return 1
  fi
  args=( "$id" firstmate --scout --also-write "$evidence" )
  if ! rows_task "$task"; then
    tester_home=$(sed -n 's/^home=//p' "$STATE/tester.meta" 2>/dev/null | tail -n 1)
    [ -n "$tester_home" ] || tester_home=${FM_TESTER_HOME:-}
    record="$tester_home/data/verify/$task.md"
    [ -n "$tester_home" ] && [ -f "$record" ] && args+=( --also-write "$record" )
  fi
  brief="$FM_HOME/data/$id/brief.md"
  # A retry after a refused spawn finds the brief it already filled; the same ask
  # reuses it, because fm-brief.sh never overwrites a brief.
  if [ -f "$brief" ] && [ "$(brief_ask "$brief")" = "$content" ]; then
    spawn_tester_launch "$id" "$harness" "$model" "$effort"
    return
  fi
  if ! FM_HOME=$FM_HOME "$BRIEF_CMD" "${args[@]}" >/dev/null 2>&1; then
    DELIVER_ERROR="Tester ask not delivered: the Tester brief could not be scaffolded"
    return 1
  fi
  intent=$(mktemp "${TMPDIR:-/tmp}/fm-tester-intent.XXXXXX") || return 1
  spec=$(mktemp "${TMPDIR:-/tmp}/fm-tester-spec.XXXXXX") || { rm -f "$intent"; return 1; }
  printf 'Verify %s on %s for %s.\nThe ask below names every scenario and width to check; record each result and its evidence.\n' \
    "$task" "$sha" "$issue_url" > "$intent"
  {
    cat "$role_md"
    # shellcheck disable=SC2016 # Markdown fences are literal
    printf '\n### The ask\n\n```json\n%s\n```\n' "$content"
  } > "$spec"
  if ! fill_brief "$brief" "$intent" "$spec"; then
    rm -f "$intent" "$spec"
    DELIVER_ERROR="Tester ask not delivered: the Tester brief could not be filled"
    return 1
  fi
  rm -f "$intent" "$spec"
  spawn_tester_launch "$id" "$harness" "$model" "$effort"
}

# Launch the Tester scout of a filled brief. A Tester carries no plan, so it
# passes the dispatch plan gate on the gate's own `verify` exemption.
spawn_tester_launch() {  # <id> <harness> <model> <effort>
  local id=$1 harness=$2 model=$3 effort=$4
  local -a sargs=( "$id" "$FM_ROOT" --scout --plan-exempt verify --harness "$harness" )
  [ -z "$model" ] || sargs+=( --model "$model" )
  [ -z "$effort" ] || sargs+=( --effort "$effort" )
  if ! FM_HOME=$FM_HOME "$SPAWN_CMD" "${sargs[@]}" >/dev/null 2>&1; then
    DELIVER_ERROR="Tester ask not delivered: the Tester spawn was refused"
    return 1
  fi
  if [ ! -f "$STATE/$id.meta" ]; then
    DELIVER_ERROR="Tester ask not delivered: the Tester spawn left no task record"
    return 1
  fi
}

# Steer an ask to the live Tester of its task. Returns 1 with DELIVER_ERROR set when the send is refused.
send_tester_ask() {  # <tester-id> <content-json>
  local id=$1 content=$2 text
  text=$(printf 'Verify ask for %s:\n%s\n' "$(jq -r .task <<<"$content")" "$content")
  if ! FM_HOME=$FM_HOME "$SEND_CMD" "$id" "$text" >/dev/null 2>&1; then
    DELIVER_ERROR="Tester ask not delivered: the steer to $id was refused"
    return 1
  fi
}

# The task record of a task begun after T5, written before its ask: the issue's user-visible check rows, then a deploy
# event that names the deployed head and the scenarios its PRs touch on a deploy round (a draft round's PR head is not
# deployed, so it names none). Both are keyed by the ask, so a retry stores nothing twice. Returns 1 with DELIVER_ERROR
# set when either is refused.
record_rows() {  # <ask-json>
  local ask=$1 task key note err
  local -a head=()
  task=$(jq -r .task <<<"$ask")
  key="deploy-verify:$(jq -r .key <<<"$ask")"
  note="deploy $(jq -r .round <<<"$ask") at $(jq -r .sha <<<"$ask"): verify ask sent ($(jq -r .issue <<<"$ask"))"
  [ "$(jq -r .round <<<"$ask")" != deploy ] || head=(--head "$(jq -r .sha <<<"$ask")")
  [ "${#head[@]}" -eq 0 ] || ! jq -e 'has("touched")' <<<"$ask" >/dev/null || head+=(--touched "$(jq -r .touched <<<"$ask")")
  if ! err=$(
    task_writer rows "$task" "$(jq -r .issue_url <<<"$ask")" --surface user-visible --key "$key:rows" --actor deploy-verify --role system 2>&1 >/dev/null &&
      task_writer event "$task" deploy --note "$note" ${head[@]+"${head[@]}"} --key "$key:deploy" --actor deploy-verify --role system 2>&1 >/dev/null
  ); then
    DELIVER_ERROR="Tester ask not delivered: the task record of $task refused its check rows: $(printf '%s' "$err" | sed -n '1p')"
    return 1
  fi
}

# The rows of a deploy ask that carry (G2, see the header): a JSON array of {key, head}. Returns 1 with DELIVER_ERROR
# set when the task record cannot be read.
carried_rows() {  # <ask-json> <dry 0|1>
  local ask=$1 dry=$2 task sha touched json
  task=$(jq -r .task <<<"$ask")
  sha=$(jq -r .sha <<<"$ask")
  touched=$(jq -r '.touched // "all"' <<<"$ask")
  if rows_task "$task"; then
    if [ "$dry" = 1 ]; then
      json=$(task_writer checks "$task" --as-deployed "$sha" --touched "$touched" 2>&1)
    else
      json=$(task_writer checks "$task" 2>&1)
    fi
    # shellcheck disable=SC2181 # the status of the assignment above
    if [ "$?" -ne 0 ] || ! jq -e '.rows | type == "array"' <<<"$json" >/dev/null 2>&1; then
      DELIVER_ERROR="Tester ask not delivered: the task record of $task could not be read: $(printf '%s' "$json" | sed -n '1p')"
      return 1
    fi
    jq -c '[.rows[] | select(.status == "pass" and (.due | not)) | {key, head}]' <<<"$json"
    return 0
  fi
  # A task begun before T5 keeps the old path: nothing carries, the Tester is asked for every row.
  printf '[]\n'
}

# A deploy ask without its carried rows: the rows and lines left, plus `carried`. A draft round passes unchanged.
narrow_ask() {  # <ask-json> <dry 0|1>
  local ask=$1 carried
  if [ "$(jq -r .round <<<"$ask")" != deploy ] || ! jq -e 'has("touched")' <<<"$ask" >/dev/null; then
    printf '%s\n' "$ask"
    return 0
  fi
  carried=$(carried_rows "$ask" "$2") || return 1
  jq -c --argjson c "$carried" '($c | map(.key)) as $k
    | .rows |= map(select((ltrimstr("- ") | split(" | ")[0]) as $r | $k | index($r) | not))
    | (.rows | map(ltrimstr("- ") | split(" | ")[0] | split("@")[0])) as $left
    | .lines |= map(select(. as $l | $left | index($l)))
    | .carried = $c' <<<"$ask"
}

env_field() {  # <file> <name>: the value of the last `<name>=` line
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

ram_read() {  # <command>: the first number its output holds (free RAM in GB)
  local out
  out=$(timeout 60 bash -c "$1" 2>/dev/null </dev/null) || return 1
  out=$(printf '%s\n' "$out" | grep -oE '[0-9]+([.][0-9]+)?' | head -n 1)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

below() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }

# The gate of one env (config/env/<name>, see the header). Sets GATE_JSON (the ask's envs entry) and GATE_HELD (why the
# ask is held, or nothing). Returns 1 with DELIVER_ERROR set when a RAM read fails.
GATE_JSON=
GATE_HELD=
env_gate() {  # <name> <file>
  local name=$1 file=$2 cmd floor recover never free after='' recovered=false
  GATE_HELD=
  cmd=$(env_field "$file" ram-read)
  floor=$(env_field "$file" floor-gb)
  recover=$(env_field "$file" recover)
  never=$(env_field "$file" never-touch | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))')
  if [ -z "$cmd" ] || ! [[ "$floor" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    GATE_JSON=$(jq -cn --arg n "$name" --argjson never "$never" '{name: $n, never_touch: $never}')
    return 0
  fi
  free=$(ram_read "$cmd") || { DELIVER_ERROR="Tester ask not delivered: the free RAM read of env $name failed"; return 1; }
  if below "$free" "$floor" && [ -n "$recover" ]; then
    timeout 300 bash -c "$recover" >/dev/null 2>&1 </dev/null || true
    recovered=true
    after=$(ram_read "$cmd") || { DELIVER_ERROR="Tester ask not delivered: the free RAM read of env $name failed after its recover step"; return 1; }
  fi
  ! below "${after:-$free}" "$floor" || GATE_HELD="env $name free RAM ${after:-$free} GB below floor $floor GB"
  GATE_JSON=$(jq -cn --arg n "$name" --argjson free "$free" --argjson floor "$floor" --argjson rec "$recovered" --arg after "$after" --argjson never "$never" \
    '{name: $n, free_gb: $free, floor_gb: $floor, recovered: $rec} + (if $after == "" then {} else {free_after_gb: ($after | tonumber)} end) + {never_touch: $never}')
}

# A wait on the Tester for the ask's rows (G1), keyed by the ask and <suffix>.
rows_wait() {  # <ask-json> <suffix> <note>
  local err
  if ! err=$(task_writer event "$(jq -r .task <<<"$1")" wait --next-actor tester --clears-on rows \
    --rows "$(jq -r '[.rows[] | ltrimstr("- ") | split(" | ")[0]] | join(",")' <<<"$1")" --note "$3" \
    --key "deploy-verify:$(jq -r .key <<<"$1"):$2" --actor deploy-verify --role system 2>&1 >/dev/null); then
    DELIVER_ERROR="Tester ask not delivered: the task record of $(jq -r .task <<<"$1") refused its wait: $(printf '%s' "$err" | sed -n '1p')"
    return 1
  fi
}

# A rows-round ask: the Tester cap, another holder's env lease, then the env gates, then the Tester's env
# leases; a held ask gets its wait and hold line, a sent ask its wait, brief or steer, and ledger line (a
# failed send gives back the leases no other ask holds).
deliver_rows_ask() {  # <ask-json>
  local ask=$1 file name envs='[]' held='' content out lease_hold=0 task tester new=0 check
  local -a names=() claimed=()
  DELIVER_HELD=0
  task=$(jq -r .task <<<"$ask")
  tester=$(tester_for_task "$task" "$ask") || tester=
  if [ -z "$tester" ]; then
    tester=$(tester_id_for_ask "$ask")
    new=1
    if [ "$(live_tester_count)" -ge "$MAX_TESTERS" ]; then
      hold_for_cap "$ask" || return 1
      return 0
    fi
  fi
  for file in "$CONFIG"/env/*; do
    [ -f "$file" ] || continue
    name=${file##*/}
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    # shellcheck disable=SC2016 # jq variables, not shell
    jq -e --arg n "$name" 'any(.env[]; contains("`" + $n + "`") or test("\\benv " + $n + "\\b"; "i"))' <<<"$ask" >/dev/null || continue
    names+=("$name")
  done
  # Another holder's live lease holds the ask before any RAM read.
  for name in ${names[@]+"${names[@]}"}; do
    out=$(env_lease check "env:$name" 2>/dev/null) || continue
    [ "${out##* }" = live ] && [ "${out%% *}" != "$tester" ] || continue
    held="$held${held:+; }env:$name is leased to ${out%% *}"
    lease_hold=1
  done
  if [ "$lease_hold" = 0 ]; then
    for name in ${names[@]+"${names[@]}"}; do
      env_gate "$name" "$CONFIG/env/$name" || return 1
      envs=$(jq -c --argjson g "$GATE_JSON" '. + [$g]' <<<"$envs")
      [ -z "$GATE_HELD" ] || held="$held${held:+; }$GATE_HELD"
    done
  fi
  ask=$(jq -c --argjson e "$envs" '. + {envs: $e}' <<<"$ask")
  if [ -n "$held" ]; then
    DELIVER_HELD=1
    rows_wait "$ask" hold "Tester ask held, not sent: $held" || return 1
    # A held lease is planned again at every poll: one hold line while the reason stays the same.
    # shellcheck disable=SC2016 # jq variables, not shell
    [ "$lease_hold" = 1 ] && ledger_test '.type == "hold" and .key == $k and .held == $h' --arg k "$(jq -r .key <<<"$ask")" --arg h "$held" && return 0
    ledger_append "$(jq -c --arg h "$held" --argjson lease "$lease_hold" --argjson at "$(date +%s)" \
      '{type: "hold", round, key, task, sha, envs, held: $h, at: $at} + (if $lease == 1 then {lease: true} else {} end)' <<<"$ask")"
    return 0
  fi
  rows_wait "$ask" wait "Tester asked for these rows on $(jq -r .sha <<<"$ask")" || return 1
  check="bin/fm-task.sh check $task <id>@<width> pass|fail --evidence <path|url> --head $(jq -r .sha <<<"$ask")"
  content=$(jq -c --arg check "$check" '{schema: "fm-tester-verify.v1", round, task, issue, issue_url, prs, sha, head, lines, rows, env, envs, check: $check}' <<<"$ask")
  # A new Tester is spawned before its lease is claimed, so a refused spawn never moves the lease from
  # another ask's holder to a task record that does not exist.
  if [ "$new" = 1 ]; then
    TESTER_ID=$tester
    spawn_tester "$ask" "$content" || return 1
  fi
  for name in ${names[@]+"${names[@]}"}; do
    if ! out=$(env_lease claim "env:$name" --holder "$tester" 2>&1); then
      release_claimed "$tester" ${claimed[@]+"${claimed[@]}"}
      DELIVER_ERROR="Tester ask not delivered: env:$name could not be leased to $tester: $(printf '%s' "$out" | sed -n '1p')"
      return 1
    fi
    claimed+=("env:$name")
  done
  ask=$(jq -c --argjson l "$(printf '%s\n' ${claimed[@]+"${claimed[@]}"} | jq -R . | jq -sc 'map(select(. != ""))')" '. + {leases: $l}' <<<"$ask")
  if [ "$new" = 0 ]; then
    send_tester_ask "$tester" "$content" || { release_claimed "$tester" ${claimed[@]+"${claimed[@]}"}; return 1; }
  fi
  ledger_append "$(jq -c --arg t "$tester" --arg c "$check" --argjson at "$(date +%s)" \
    'del(.arrival) + {type: "ask", tester: $t, check: $c, at: $at}' <<<"$ask")"
}

# Give back the leases this delivery claimed, except one another ask still holds (lease_asks): the delivery's claim only
# refreshed that lease, and release_landed_leases ends it when those asks land.
release_claimed() {  # <tester-id> <env:name>...
  local holder=$1 lease
  shift
  for lease in "$@"; do
    [ "$(lease_asks "$lease" | jq length)" -eq 0 ] || continue
    env_lease release "$lease" --holder "$holder" >/dev/null 2>&1 || true
  done
}

deliver_ask() {  # <ask-json>
  local ask=$1 content check='' rows_task=0 task tester new=0
  [ "$(jq -r .round <<<"$ask")" != rows ] || { deliver_rows_ask "$ask"; return; }
  DELIVER_HELD=0
  task=$(jq -r .task <<<"$ask")
  # A task begun after T5 is verified on its check rows in the task record: they are written first, and the ask names
  # the call for each result.
  if rows_task "$task"; then
    rows_task=1
    record_rows "$ask" || return 1
    check="bin/fm-task.sh check $task <id>@<width> pass|fail --evidence <path|url> --head $(jq -r .sha <<<"$ask")"
  fi
  ask=$(narrow_ask "$ask" 0) || return 1
  # Every row carries: nothing is due on this head, so no ask goes out and the ledger records the carry.
  if jq -e '.round == "deploy" and (.rows | length) == 0 and (.carried | length) > 0' <<<"$ask" >/dev/null; then
    ledger_append "$(jq -c --argjson at "$(date +%s)" '{type: "carry", round, key, task, prs, sha, carried, at: $at}' <<<"$ask")"
    return 0
  fi
  tester=$(tester_for_task "$task" "$ask") || tester=
  if [ -z "$tester" ]; then
    tester=$(tester_id_for_ask "$ask")
    new=1
    if [ "$(live_tester_count)" -ge "$MAX_TESTERS" ]; then
      hold_for_cap "$ask" || return 1
      return 0
    fi
  fi
  content=$(jq -c --arg check "$check" 'del(.arrival, .key) + {schema: "fm-tester-verify.v1", check: (if $check == "" then null else $check end)}
    | {schema, round, task, issue, issue_url, prs, sha, run, head, pushed, lines, rows, touched, carried, check}
    | with_entries(select(.value != null))' <<<"$ask")
  if [ "$new" = 1 ]; then
    TESTER_ID=$tester
    spawn_tester "$ask" "$content" || return 1
  else
    send_tester_ask "$tester" "$content" || return 1
  fi
  ledger_append "$(jq -c --arg t "$tester" --arg c "$check" --argjson at "$(date +%s)" \
    'del(.arrival) + {type: "ask", tester: $t, at: $at} + (if $c == "" then {} else {check: $c} end)' <<<"$ask")"
  # Opt-in task record shadow (bin/fm-task-shadow.sh): the delivered ask is a deploy event of its task; off costs one file test.
  # A task begun after T5 has its deploy event already.
  [ ! -e "$CONFIG/task-shadow" ] || [ "$rows_task" = 1 ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-task-shadow.sh" deploy-verify \
    "$(jq -r .task <<<"$ask")" "$(jq -r .sha <<<"$ask")" "$(jq -r .round <<<"$ask")" "$(jq -r .issue <<<"$ask")" >/dev/null 2>&1 || true
}

cmd_autohandle() {  # <source-id> <sequence> <result-file>
  local sid=${1:-} seq=${2:-} result=${3:-} ask failed=0 held=0 reason='' previous='' pr task skip
  [ "$sid" = "$SOURCE_ID" ] && [ -f "$result" ] || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  jq -e '.schema == "fm-deploy-verify-result.v1"' "$result" >/dev/null 2>&1 || return 1
  # A GitHub failure is left unacknowledged on purpose: that is the one wake.
  jq -e '.error == null' "$result" >/dev/null 2>&1 || return 1
  mkdir -p "$DATA"
  # This receipt belongs to this result only, never to a historical ledger hold.
  rm -f "$result.holds"
  while IFS= read -r skip; do
    [ -n "$skip" ] || continue
    pr=$(jq -r .pr <<<"$skip")
    task=$(jq -r .task <<<"$skip")
    ledger_pr_final "$pr" "$task" && continue
    ledger_append "$(jq -c --argjson at "$(date +%s)" '{type: "skip", pr, task, reason, at: $at} + (if .detail then {detail} else {} end)' <<<"$skip")"
  done < <(jq -c '.skips[]' "$result")
  reason=
  while IFS= read -r ask; do
    [ -n "$ask" ] || continue
    ledger_has_key "$(jq -r .key <<<"$ask")" && continue
    if ! deliver_ask "$ask"; then
      failed=1
      [ -n "$reason" ] || reason=$DELIVER_ERROR
    fi
    if [ "$DELIVER_HELD" = 1 ] && [ "$failed" = 0 ]; then
      held=1
      jq -r .key <<<"$ask" >> "$result.holds"
    fi
  done < <(jq -c '.asks[]' "$result")
  if [ "$failed" -eq 1 ]; then
    [ ! -f "$LAST_ERROR" ] || previous=$(<"$LAST_ERROR")
    printf '%s\n' "$reason" > "$LAST_ERROR"
    # The same failure was announced already: stay quiet and retry next poll.
    [ "$previous" = "$reason" ] || return 1
    "$SCRIPT_DIR/fm-procevent.sh" handled "$SOURCE_ID" "$seq" >/dev/null 2>&1 || true
    return 0
  fi
  # A held ask is planned again next poll, so the cursor waits for it.
  if [ "$held" -eq 0 ] && jq -e '.cursor != null' "$result" >/dev/null 2>&1; then
    state_put "$(jq -r .cursor.cursor_run "$result")" "$(jq -r .cursor.last_green_sha "$result")"
  fi
  rm -f "$LAST_ERROR"
  attention_skip "$result" && return 1
  mark_handled "$seq"
}

cmd_silent() {  # <result-file>
  local result=${1:-} ask pr task
  attention_skip "$result" && return 1
  jq -e '.schema == "fm-deploy-verify-result.v1" and .error == null' "$result" >/dev/null 2>&1 || return 1
  while IFS= read -r ask; do
    # Only this result's successful hold receipt can silence a hold; old ledger holds cannot.
    ledger_has_key "$(jq -r .key <<<"$ask")" \
      || grep -Fxq -- "$(jq -r .key <<<"$ask")" "$result.holds" 2>/dev/null \
      || return 1
  done < <(jq -c '.asks[]' "$result")
  while IFS='|' read -r pr task; do
    ledger_pr_final "$pr" "$task" || return 1
  done < <(jq -r '.skips[] | [.pr, .task] | join("|")' "$result")
}

cmd_classify() {  # <result-file>
  local result=${1:-}
  if jq -e '.error != null' "$result" >/dev/null 2>&1; then
    printf 'error\n'
  elif jq -e '(.asks | length) > 0' "$result" >/dev/null 2>&1; then
    printf 'asks\n'
  else
    printf 'record\n'
  fi
}

cmd_deploy() {  # --dry-run --sha <sha> [--base <sha>]
  local dry=0 sha='' base='' w ask out='[]'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --sha) sha=${2:-}; shift 2 || break ;;
      --base) base=${2:-}; shift 2 || break ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 0 ] && [ "$dry" = 1 ] && [ -n "$sha" ] || die 'usage: deploy --dry-run --sha <sha> [--base <sha>]'
  [ -n "$base" ] || base=$(jq -r '.last_green_sha // ""' "$CURSOR" 2>/dev/null)
  w=$(mktemp -d "${TMPDIR:-/tmp}/fm-deploy-dry.XXXXXX") || return 1
  READ_ERROR_FILE="$w/.read-error"
  build_map "$w/map.psv"
  PLAN_IGNORE_LEDGER=1
  if ! plan_deploy "$base" "$sha" '' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$w"; then
    printf 'error: %s\n' "$(cat "$READ_ERROR_FILE" 2>/dev/null)" >&2
    rm -rf "$w"
    return 1
  fi
  rm -rf "$w"
  while IFS= read -r ask; do
    [ -n "$ask" ] || continue
    ask=$(narrow_ask "$ask" 1) || { printf 'error: %s\n' "$DELIVER_ERROR" >&2; return 1; }
    out=$(jq -c --argjson a "$ask" '. + [$a]' <<<"$out")
  done < <(jq -c '.[]' <<<"$ASKS")
  jq -cn --argjson asks "$out" --argjson skips "$SKIPS" '{asks: $asks, skips: $skips}'
}

cmd_ask_rows() {  # <task> [--dry-run]
  local task=${1:-} dry=0 ask rc=0
  case "${2:-}" in --dry-run) dry=1 ;; '') ;; *) die 'usage: ask-rows <task> [--dry-run]' ;; esac
  [ "$#" -le 2 ] && [ -n "$task" ] || die 'usage: ask-rows <task> [--dry-run]'
  rows_task "$task" || die "$task has no 'record: rows' in $FM_HOME/data/$task/verify.md"
  if [ "$dry" = 1 ]; then
    READ_ERROR_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-deploy-rows.XXXXXX") || return 1
  else
    mkdir -p "$DATA"
  fi
  if ! plan_rows_task "$task"; then
    printf 'error: %s\n' "$(cat "$READ_ERROR_FILE" 2>/dev/null)" >&2
    [ "$dry" = 0 ] || rm -f "$READ_ERROR_FILE"
    return 1
  fi
  [ "$dry" = 0 ] || rm -f "$READ_ERROR_FILE"
  while IFS= read -r ask; do
    [ -n "$ask" ] || continue
    if [ "$dry" = 0 ] && ! deliver_ask "$ask"; then
      printf 'error: %s\n' "$DELIVER_ERROR" >&2
      rc=1
      continue
    fi
    printf '%s\n' "$ask"
  done < <(jq -c '.[]' <<<"$ASKS")
  return "$rc"
}

cmd_arm() {
  "$SCRIPT_DIR/fm-procevent.sh" register deploy-verify "$SOURCE_ID" -- "$SCRIPT_DIR/fm-procevent-deploy-verify.sh" wait
}

case "${1:-}" in
  replay-skips) shift; cmd_replay_skips "$@" ;;
  deploy) shift; cmd_deploy "$@" ;;
  ask-rows) shift; cmd_ask_rows "$@" ;;
  arm) shift; cmd_arm "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || die 'usage: autohandle <source-id> <sequence> <result-file>'; cmd_autohandle "$@" ;;
  classify) shift; cmd_classify "$@" ;;
  silent) shift; cmd_silent "$@" ;;
  terminal) exit 1 ;;
  self-announcing|relisten) exit 0 ;;
  *) echo 'error: expected replay-skips, deploy, ask-rows, arm, wait, autohandle, classify, silent, terminal, self-announcing or relisten' >&2; exit 2 ;;
esac
