#!/usr/bin/env bash
# fm-bearings-snapshot.sh - compact, bounded, TOON-by-default bearings projection.
#
# A thin wrapper OVER the canonical bin/fm-fleet-snapshot.sh. It does not parse
# fleet state itself: it shells out to `fm-fleet-snapshot.sh --json`, projects that
# complete structured contract down to the small set of fields a "pick up where I
# left off" read needs, and renders TOON at the output boundary. The internal data
# model stays JSON (`--json` prints it verbatim); TOON is the default agent-facing
# format per the AXI standard, and TOON/JSON are parity representations of the same
# projected model. The projection is view-specific: it DROPS fields from the bearings
# output, it never removes them from - or otherwise weakens - the canonical snapshot,
# which stays complete.
#
# Every PR URL the projection names is checked live at render time through gh-axi.
# A locally recorded pr= row is only a candidate URL, never forge-state evidence.
# The default verifies URLs already selected from task metadata and the bounded
# landed baseline; --include-prs additionally discovers open PRs in candidate repos.
# An unreachable or unsupported forge remains in the result as NOT_VERIFIABLE.
# The firstmate upstream check surface enumerates every Actions run instance with
# event, attempt, and timestamp; it never collapses duplicate event-payload checks
# into a pass/fail tally.
#
# This wrapper consumes canonical status decisions plus canonically normalized
# backlog roles, unresolved blockers, and captain actionability. It never infers
# decisions from report or visual-review prose or reimplements snapshot semantics.
#
# Main-home inventory validity comes from the canonical snapshot's main_inventory
# object (orphan structured in-flight without meta, unstructured current rows).
# Bearings never invents Underway rows from backlog-only ids; it discloses those
# gaps in omitted[] and, when invalid, a Charted Next gate line so the four-section
# chat cannot claim an empty fleet while main current state is broken.
#
# The landed section merges this home's Done with the canonical snapshot's
# secondmate_landed roll-up (fm-fleet-snapshot.sh), so merges a secondmate managed -
# recorded in ITS OWN backlog, never the main one - are visible. It stays bounded by
# a per-home cap and an overall cap, with omitted[] disclosure of both and of any
# secondmate home whose backlog was unreadable. Each selected PR artifact is then
# live-verified; the local landed selection itself remains deterministic.
# The default landed baseline is balanced across homes: each home keeps its internal
# newest-first ordering, homes iterate in deterministic id order, and sparse homes do
# not waste capacity.
#
# Flags:
#   (default)        compact projection, TOON, live-verifies every named PR
#   --json           the same projected model as JSON (machine/debug; parity form)
#   --include-prs    ALSO do live open-PR discovery in candidate repositories
#   --fields <list>  opt in to dropped surfaces: bodies,paths,actions,endpoints
#   -h,--help        usage
#
# Output contract: `fm-bearings.v1`. Read-only; no locks, no mutation, no reports.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/fm-fleet-snapshot.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
EVIDENCE_RUN="$SCRIPT_DIR/fm-evidence-run.sh"

# Bounds (overridable for tests / large fleets).
FM_BEARINGS_LANDED=${FM_BEARINGS_LANDED:-6}
FM_BEARINGS_LANDED_PER_HOME=${FM_BEARINGS_LANDED_PER_HOME:-$FM_BEARINGS_LANDED}
FM_BEARINGS_IN_FLIGHT=${FM_BEARINGS_IN_FLIGHT:-20}
FM_BEARINGS_DECISIONS=${FM_BEARINGS_DECISIONS:-20}
FM_BEARINGS_SECONDMATES=${FM_BEARINGS_SECONDMATES:-20}
FM_BEARINGS_GATES=${FM_BEARINGS_GATES:-20}
FM_BEARINGS_REPORTS=${FM_BEARINGS_REPORTS:-20}
FM_BEARINGS_RECORDED_PRS=${FM_BEARINGS_RECORDED_PRS:-20}
FM_BEARINGS_UNHEALTHY=${FM_BEARINGS_UNHEALTHY:-20}
FM_BEARINGS_PR_REPOS=${FM_BEARINGS_PR_REPOS:-10}
FM_BEARINGS_PR_LIMIT=${FM_BEARINGS_PR_LIMIT:-20}
FM_BEARINGS_PR_TIMEOUT=${FM_BEARINGS_PR_TIMEOUT:-20}
case "$FM_BEARINGS_PR_TIMEOUT" in ''|*[!0-9]*|0) FM_BEARINGS_PR_TIMEOUT=20 ;; esac
validate_bound() {  # <name> <value>
  case "$2" in ''|*[!0-9]*|0) echo "fm-bearings-snapshot: $1 must be a positive integer" >&2; exit 2 ;; esac
}
validate_bound FM_BEARINGS_LANDED "$FM_BEARINGS_LANDED"
validate_bound FM_BEARINGS_LANDED_PER_HOME "$FM_BEARINGS_LANDED_PER_HOME"
validate_bound FM_BEARINGS_IN_FLIGHT "$FM_BEARINGS_IN_FLIGHT"
validate_bound FM_BEARINGS_DECISIONS "$FM_BEARINGS_DECISIONS"
validate_bound FM_BEARINGS_SECONDMATES "$FM_BEARINGS_SECONDMATES"
validate_bound FM_BEARINGS_GATES "$FM_BEARINGS_GATES"
validate_bound FM_BEARINGS_REPORTS "$FM_BEARINGS_REPORTS"
validate_bound FM_BEARINGS_RECORDED_PRS "$FM_BEARINGS_RECORDED_PRS"
validate_bound FM_BEARINGS_UNHEALTHY "$FM_BEARINGS_UNHEALTHY"
validate_bound FM_BEARINGS_PR_REPOS "$FM_BEARINGS_PR_REPOS"
validate_bound FM_BEARINGS_PR_LIMIT "$FM_BEARINGS_PR_LIMIT"

usage() {
  cat <<'EOF'
usage: fm-bearings-snapshot.sh [--json] [--include-prs] [--fields <list>]

Compact bearings projection over fm-fleet-snapshot.sh. TOON by default.
Every PR URL named by the output is verified live; --include-prs also discovers.

Default fields: schema, home, generated, prs, in_flight{id,kind,state,doing},
  secondmates{id,state,doing,provenance,freshness,age_seconds,contradiction,reason},
  decisions_open{id,key,verb,summary,owner}, landed{id,what,artifact,owner},
  gates{id,title,blocked_by,reason,owner}, reports{id,path}, recorded_prs{id,url},
  unhealthy_endpoints{...} (only when non-empty), omitted{surface,reveal}.
portfolio_bounds{surface,shown,total,omitted,rest} appears only when a fleet
  portfolio section dropped rows and names the environment bound that retrieves them.
landed merges this home's Done with registered secondmate homes' Done, bounded by
  a per-home cap (FM_BEARINGS_LANDED_PER_HOME) and an overall cap (FM_BEARINGS_LANDED),
  with omitted[] disclosure. Default selection is balanced across deterministic home
  order while preserving each home's internal newest-first order; sparse homes do
  not waste capacity.
For every registered secondmate, readable structured facts from its own home are
  authoritative, including independently trustworthy surfaces from a partial summary.
  Parent events and bounded terminal reads are labeled fallback or contradiction
  evidence and never become current work.
Opt-in surfaces: --fields bodies|paths|actions|endpoints and --include-prs
  (adds bounded candidate_prs discovery).
Raise FM_BEARINGS_PR_LIMIT to expand per-repository open-PR results.
EOF
}

FORMAT=toon
INCLUDE_PRS=0
FIELDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --include-prs) INCLUDE_PRS=1 ;;
    --fields) shift; FIELDS=${1:-} ;;
    --fields=*) FIELDS=${1#--fields=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-bearings-snapshot: jq not found" >&2; exit 1; }

# The deterministic return-catch-up owner must clear before this or any other
# ordinary captain request proceeds. Bearings does not reproduce that policy;
# it only consults the shared read-only gate.
"$SCRIPT_DIR/fm-afk-return.sh" guard || exit $?

NOW=${FM_BEARINGS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
SNAP=$(FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_INCLUDE_LIVENESS=1 "$FLEET" --json) || exit $?
HOME_LABEL=$(printf '%s' "$SNAP" | jq -er '.fm_home | strings | split("/") | (.[-2:] | join("/"))') \
  || { echo "fm-bearings-snapshot: invalid canonical snapshot" >&2; exit 1; }
BEARINGS_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings.XXXXXX") || exit 1
cleanup_bearings_tmp() { rm -rf -- "$BEARINGS_TMP"; }
trap cleanup_bearings_tmp EXIT HUP INT TERM
LANDED_SELECTION_FILE="$BEARINGS_TMP/landed-selection.json"
CANDIDATE_PRS_FILE="$BEARINGS_TMP/candidate-prs.json"
PR_DISCOVERY_FILE="$BEARINGS_TMP/pr-discovery.json"
PR_DISCOVERY_ROWS_FILE="$BEARINGS_TMP/pr-discovery.jsonl"
PR_VERIFICATION_ROWS_FILE="$BEARINGS_TMP/pr-verification.jsonl"
: > "$PR_DISCOVERY_ROWS_FILE"
: > "$PR_VERIFICATION_ROWS_FILE"

printf '%s' "$SNAP" | jq \
  --argjson landed_n "$FM_BEARINGS_LANDED" \
  --argjson landed_per_home_n "$FM_BEARINGS_LANDED_PER_HOME" '
  def round_robin_landed($n):
    . as $groups
    | [range(0; (($groups | map(length) | max) // 0)) as $i
       | $groups[]
       | select(length > $i)
       | .[$i]][:$n];
  ([ .backlog.records[] | select(.state == "done" and .structured and .kind != "captain")
     | {id, title, pr_url, report_path, local_note, completion, home:"(main)", home_id:"(main)"} ]) as $main_done
  | ((.secondmate_landed.records) // []) as $mate_done
  | ($main_done + $mate_done) as $all_rows
  | ([ .secondmate_current.records[]?
       | select(.provenance.selected == "structured-home")
       | ((.counts.landed // (.landed | length)) - (.landed | length))
       | select(. > 0) ] | add // 0) as $upstream_omitted
  | ([ $all_rows | group_by(.home_id)[]
       | sort_by([(.completion.date // ""), .id]) | reverse
       | .[:$landed_per_home_n] ]) as $groups
  | ($groups | add // []) as $per_home_capped
  | {
      selected:($groups | round_robin_landed($landed_n)),
      per_home_capped_count:($per_home_capped | length),
      home_cap_dropped:([ $all_rows | group_by(.home_id)[] | select(length > $landed_per_home_n) ] | length),
      total_count:(($all_rows | length) + $upstream_omitted)
    }' > "$LANDED_SELECTION_FILE" \
  || { echo "fm-bearings-snapshot: landed selection failed" >&2; exit 1; }

# --- live verification for every PR URL the projection can name ------------
PR_STATUS='checked (0 PRs named)'
PR_REPOS_TOTAL=0
PR_REPOS_SHOWN=0
PR_ROWS_CAPPED=0
PR_ROWS_MIN_TOTAL=0
RECORDED_URL_TOTAL=$(printf '%s' "$SNAP" | jq '[.tasks[] | select(.kind != "secondmate") | .pr.url // empty] | length')

# Parse owner/repo from an https or ssh GitHub remote/PR URL; empty if not GitHub.
repo_slug() {  # <url>
  printf '%s' "$1" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' | sed 's#\.git$##; s#/pull/.*$##; s#/$##'
}

# Bounded gh-axi call; prints stdout, non-zero on timeout/failure.
ghaxi_bounded() {  # <args...>
  GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    "$EVIDENCE_RUN" --total "$FM_BEARINGS_PR_TIMEOUT" gh-axi "$@"
}

decode_api_body() {
  local payload encoded truncated
  payload=$(cat)
  truncated=$(printf '%s\n' "$payload" | sed -n 's/^[[:space:]]*truncated: //p' | head -1)
  [ "$truncated" = false ] || return 1
  encoded=$(printf '%s\n' "$payload" | sed -n 's/^[[:space:]]*body: //p' | head -1)
  [ -n "$encoded" ] || return 1
  printf '%s' "$encoded" | jq -er '.'
}

URLS=""
add_pr_url() {  # <url>
  local url=$1
  [ -n "$url" ] || return 0
  case "
$URLS
" in *"
$url
"*) return 0 ;; esac
  URLS="${URLS}${URLS:+
}$url"
}

# URLs that can otherwise appear in recorded_prs or the final landed selection.
while IFS= read -r url; do add_pr_url "$url"; done <<EOF
$(printf '%s' "$SNAP" | jq -r --argjson limit "$FM_BEARINGS_RECORDED_PRS" '[.tasks[] | select(.kind != "secondmate") | .pr.url // empty][:$limit][]')
$(jq -r '.selected[] | .pr_url // empty' "$LANDED_SELECTION_FILE")
EOF

repos=""
while IFS= read -r url; do
  [ -n "$url" ] || continue
  slug=$(repo_slug "$url")
  [ -n "$slug" ] || continue
  case " $repos " in *" $slug "*) ;; *) repos="$repos $slug" ;; esac
done <<EOF
$URLS
EOF

if [ "$INCLUDE_PRS" = 1 ]; then
  while IFS= read -r wt; do
    [ -d "$wt" ] || continue
    origin=$(git -C "$wt" remote get-url origin 2>/dev/null) || continue
    slug=$(repo_slug "$origin")
    [ -n "$slug" ] || continue
    case " $repos " in *" $slug "*) ;; *) repos="$repos $slug" ;; esac
  done <<EOF
$(printf '%s' "$SNAP" | jq -r '.tasks[] | select(.kind != "secondmate") | .paths.worktree.path // empty')
EOF
  for repo in $repos; do PR_REPOS_TOTAL=$((PR_REPOS_TOTAL + 1)); done
  nrepos=0
  for repo in $repos; do
    if [ "$nrepos" -ge "$FM_BEARINGS_PR_REPOS" ]; then break; fi
    nrepos=$((nrepos + 1))
    pr_fetch_limit=$((FM_BEARINGS_PR_LIMIT + 1))
    if ! api=$(ghaxi_bounded api "repos/$repo/pulls?state=open&per_page=$pr_fetch_limit" \
      --jq 'map(.html_url) | join("\n")' 2>/dev/null); then
      discovery=$(jq -n --arg repo "$repo" \
        '{repo:$repo,verification:"NOT_VERIFIABLE",reason:"open PR discovery query failed or timed out",returned:null,complete:false}')
      printf '%s\n' "$discovery" >> "$PR_DISCOVERY_ROWS_FILE"
      continue
    fi
    if [ "$(printf '%s\n' "$api" | sed -n 's/^[[:space:]]*truncated: //p' | head -1)" != false ]; then
      discovery=$(jq -n --arg repo "$repo" \
        '{repo:$repo,verification:"NOT_VERIFIABLE",reason:"open PR discovery response was truncated",returned:null,complete:false}')
      printf '%s\n' "$discovery" >> "$PR_DISCOVERY_ROWS_FILE"
      continue
    fi
    if ! discovered=$(printf '%s\n' "$api" | decode_api_body 2>/dev/null); then
      discovery=$(jq -n --arg repo "$repo" \
        '{repo:$repo,verification:"NOT_VERIFIABLE",reason:"open PR discovery response was malformed",returned:null,complete:false}')
      printf '%s\n' "$discovery" >> "$PR_DISCOVERY_ROWS_FILE"
      continue
    fi
    returned=0
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      returned=$((returned + 1))
      [ "$returned" -le "$FM_BEARINGS_PR_LIMIT" ] && add_pr_url "$url"
    done <<EOF
$discovered
EOF
    if [ "$returned" -gt "$FM_BEARINGS_PR_LIMIT" ]; then
      PR_ROWS_CAPPED=$((PR_ROWS_CAPPED + 1))
      discovery=$(jq -n --arg repo "$repo" --argjson returned "$returned" --argjson limit "$FM_BEARINGS_PR_LIMIT" \
        '{repo:$repo,verification:"NOT_VERIFIABLE",reason:("open PR discovery exceeded the per-repository limit of " + ($limit|tostring)),returned:$returned,complete:false}')
    else
      discovery=$(jq -n --arg repo "$repo" --argjson returned "$returned" \
        '{repo:$repo,verification:"verified_live",reason:null,returned:$returned,complete:true}')
    fi
    printf '%s\n' "$discovery" >> "$PR_DISCOVERY_ROWS_FILE"
  done
  PR_REPOS_SHOWN=$nrepos
fi

named=0
unverified=0
while IFS= read -r url; do
  [ -n "$url" ] || continue
  named=$((named + 1))
  repo=$(repo_slug "$url")
  num=$(printf '%s' "$url" | sed -n 's#^https://github\.com/[^/]*/[^/]*/pull/\([0-9][0-9]*\)/*$#\1#p')
  task=$(printf '%s' "$SNAP" | jq -r --arg url "$url" '[.tasks[] | select(.pr.url==$url) | .id][0] // "-"')
  if [ -z "$repo" ] || [ -z "$num" ] || ! command -v gh-axi >/dev/null 2>&1; then
    jq -n -c --arg num "${num:--}" --arg repo "${repo:--}" --arg task "$task" --arg url "$url" \
      '{num:$num,repo:$repo,task:$task,url:$url,title:"NOT_VERIFIABLE",state:"NOT_VERIFIABLE",mergedAt:"NOT_VERIFIABLE",head:"NOT_VERIFIABLE",checks:"NOT_VERIFIABLE",actions:null,verification:"NOT_VERIFIABLE"}' \
      >> "$PR_VERIFICATION_ROWS_FILE"
    unverified=$((unverified + 1))
    continue
  fi
  api=$(ghaxi_bounded api "repos/$repo/pulls/$num" \
    --jq '[.number,.title,.state,(.merged_at // "-"),.html_url,.head.sha,.head.ref] | @tsv' 2>/dev/null) || api=
  details=$(printf '%s\n' "$api" | decode_api_body 2>/dev/null) || details=
  if [ -z "$details" ]; then
    jq -n -c --arg num "$num" --arg repo "$repo" --arg task "$task" --arg url "$url" \
      '{num:$num,repo:$repo,task:$task,url:$url,title:"NOT_VERIFIABLE",state:"NOT_VERIFIABLE",mergedAt:"NOT_VERIFIABLE",head:"NOT_VERIFIABLE",checks:"NOT_VERIFIABLE",actions:null,verification:"NOT_VERIFIABLE"}' \
      >> "$PR_VERIFICATION_ROWS_FILE"
    unverified=$((unverified + 1))
    continue
  fi
  IFS=$(printf '\t') read -r live_num title state merged_at canonical_url head_sha head_ref <<EOF
$details
EOF
  case "$live_num:$state:$canonical_url:$head_sha:$head_ref" in
    "$num:open:https://github.com/$repo/pull/$num":?*:?*|"$num:closed:https://github.com/$repo/pull/$num":?*:?*) ;;
    *)
      jq -n -c --arg num "$num" --arg repo "$repo" --arg task "$task" --arg url "$url" \
        '{num:$num,repo:$repo,task:$task,url:$url,title:"NOT_VERIFIABLE",state:"NOT_VERIFIABLE",mergedAt:"NOT_VERIFIABLE",head:"NOT_VERIFIABLE",checks:"NOT_VERIFIABLE",actions:null,verification:"NOT_VERIFIABLE"}' \
        >> "$PR_VERIFICATION_ROWS_FILE"
      unverified=$((unverified + 1))
      continue
      ;;
  esac
  [ "$merged_at" != - ] && live_state=MERGED || live_state=$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')
  runs_api=$(ghaxi_bounded api "repos/$repo/actions/runs?head_sha=$head_sha&per_page=100" \
    --jq '{total_count:.total_count,returned:(.workflow_runs|length),runs:(.workflow_runs | map({name:.name,event:.event,attempt:.run_attempt,created:.created_at,updated:.updated_at,status:.status,conclusion:(.conclusion // "pending"),url:.html_url}))}' 2>/dev/null) || runs_api=
  runs=$(printf '%s\n' "$runs_api" | decode_api_body 2>/dev/null) || runs=
  checks=NOT_VERIFIABLE
  actions_file="$BEARINGS_TMP/actions.json"
  checks_file="$BEARINGS_TMP/checks.txt"
  printf 'null\n' > "$actions_file"
  if [ -n "$runs" ] && printf '%s' "$runs" | jq -e '
    (.total_count | type) == "number" and (.returned | type) == "number"
      and (.runs | type) == "array"
      and all(.runs[];
        (.name | type) == "string" and (.event | type) == "string"
        and (.attempt | type) == "number" and (.created | type) == "string"
        and (.updated | type) == "string" and (.status | type) == "string"
        and (.conclusion | type) == "string" and (.url | type) == "string"
        and (.url | startswith("https://")))
  ' >/dev/null 2>&1; then
    runs_total=$(printf '%s' "$runs" | jq -r '.total_count')
    runs_returned=$(printf '%s' "$runs" | jq -r '.returned')
    if [ "$runs_total" != "$runs_returned" ]; then
      checks="NOT_VERIFIABLE: Actions run list returned $runs_returned of $runs_total"
    elif [ "$runs_returned" = 0 ]; then
      checks=none
      printf '[]\n' > "$actions_file"
    else
      printf '%s' "$runs" | jq '.runs' > "$actions_file"
      checks=$(printf '%s' "$runs" | jq -r '[.runs[] | "\(.name)[event=\(.event) attempt=\(.attempt) created=\(.created) updated=\(.updated) status=\(.status) conclusion=\(.conclusion) url=\(.url)]"] | join("; ")')
    fi
  elif [ -n "$runs" ]; then
    checks="NOT_VERIFIABLE: Actions instances lacked event, attempt, timestamp, status, conclusion, or URL evidence"
  fi
  printf '%s' "$checks" > "$checks_file"
  jq -n -c --arg num "$live_num" --arg repo "$repo" --arg task "$task" \
    --arg url "$canonical_url" --arg title "$title" --arg state "$live_state" \
    --arg mergedAt "$merged_at" --arg head "$head_ref@$head_sha" \
    --slurpfile actions_input "$actions_file" \
    --rawfile checks_input "$checks_file" \
    '{num:$num,repo:$repo,task:$task,url:$url,title:$title,state:$state,
      mergedAt:(if $mergedAt=="-" then null else $mergedAt end),head:$head,checks:$checks_input,
      actions:$actions_input[0],verification:"verified_live"}' >> "$PR_VERIFICATION_ROWS_FILE"
done <<EOF
$URLS
EOF
jq -s '.' "$PR_VERIFICATION_ROWS_FILE" > "$CANDIDATE_PRS_FILE"
jq -s '.' "$PR_DISCOVERY_ROWS_FILE" > "$PR_DISCOVERY_FILE"
PR_ROWS_MIN_TOTAL=$named
if [ "$unverified" -gt 0 ]; then
  PR_STATUS="checked ($named named; $unverified NOT_VERIFIABLE)"
else
  PR_STATUS="checked ($named named; all verified live)"
fi
discovery_unverified=$(jq '[.[] | select(.verification == "NOT_VERIFIABLE")] | length' "$PR_DISCOVERY_FILE")
if [ "$discovery_unverified" -gt 0 ]; then
  PR_STATUS="$PR_STATUS; discovery NOT_VERIFIABLE for $discovery_unverified repo(s)"
fi

# --- projection: canonical snapshot -> fm-bearings.v1 model (JSON) ----------
MODEL=$(printf '%s' "$SNAP" | jq \
  --arg home "$HOME_LABEL" \
  --arg now "$NOW" \
  --arg prs "$PR_STATUS" \
  --arg fields "$FIELDS" \
  --argjson landed_n "$FM_BEARINGS_LANDED" \
  --argjson landed_per_home_n "$FM_BEARINGS_LANDED_PER_HOME" \
  --argjson in_flight_n "$FM_BEARINGS_IN_FLIGHT" \
  --argjson decisions_n "$FM_BEARINGS_DECISIONS" \
  --argjson secondmates_n "$FM_BEARINGS_SECONDMATES" \
  --argjson gates_n "$FM_BEARINGS_GATES" \
  --argjson reports_n "$FM_BEARINGS_REPORTS" \
  --argjson recorded_prs_n "$FM_BEARINGS_RECORDED_PRS" \
  --argjson unhealthy_n "$FM_BEARINGS_UNHEALTHY" \
  --argjson include_prs "$INCLUDE_PRS" \
  --argjson pr_repos_total "$PR_REPOS_TOTAL" \
  --argjson pr_repos_shown "$PR_REPOS_SHOWN" \
  --argjson pr_rows_capped "$PR_ROWS_CAPPED" \
  --argjson pr_rows_min_total "$PR_ROWS_MIN_TOTAL" \
  --argjson recorded_url_total "$RECORDED_URL_TOTAL" \
  --slurpfile landed_selection_input "$LANDED_SELECTION_FILE" \
  --slurpfile candidate_prs_input "$CANDIDATE_PRS_FILE" \
  --slurpfile pr_discovery_input "$PR_DISCOVERY_FILE" '
  def trunc($n): if . == null then null else
    (tostring | gsub("\\s+"; " ") | if (length > $n) then (.[:$n] + "…") else . end) end;
  def normalized_pr_url: sub("/+$"; "");
  def effectively_working: (.current_state.state == "working" or .liveness.activity == "active");
  def portfolio_bound($surface; $shown; $total; $rest):
    {surface:$surface,shown:$shown,total:$total,omitted:($total-$shown),rest:$rest};
  ($landed_selection_input[0]) as $landed_selection
  | ($candidate_prs_input[0]) as $candidate_prs
  | ($pr_discovery_input[0]) as $pr_discovery
  | ($fields | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $fl
  | (($fl | index("bodies")) != null) as $f_bodies
  | (($fl | index("paths")) != null) as $f_paths
  | (($fl | index("actions")) != null) as $f_actions
  | (($fl | index("endpoints")) != null) as $f_endpoints
  | ([ $landed_selection.selected[] as $row
       | if $row.pr_url == null then $row
         else ([ $candidate_prs[]
                  | select((.url | normalized_pr_url) == ($row.pr_url | normalized_pr_url)) ][0]) as $live_pr
         | select($live_pr.verification == "verified_live" and $live_pr.state == "MERGED")
         | $row
         end ]) as $done
  | ($landed_selection.selected | length) as $landed_selected_count
  | ($landed_selected_count - ($done | length)) as $landed_live_rejected_count
  | ($landed_selection.per_home_capped_count) as $per_home_capped_count
  | ($landed_selection.home_cap_dropped) as $home_cap_dropped
  | ($landed_selection.total_count) as $landed_total_count
  | ($done | map(.id)) as $done_ids
  | ([.tasks[] | select(.kind != "secondmate") | .id]) as $live_ids
  | ($live_ids + $done_ids) as $rel_ids
  | ([ .tasks[]
       | select(.liveness.endpoint.presence != "verified_present" or .liveness.worker.presence != "verified_present")
       | {id, backend, target:(.endpoint.target // "-"), endpoint:.liveness.endpoint.presence,
          worker:.liveness.worker.presence,activity:.liveness.activity,
          evidence_grade:(.liveness.evidence.grade // "unverified")} ]
     + [ (.secondmate_current.records // [])[] as $m | $m.endpoints[]?
         | select(.endpoint.exists == false or .endpoint.agent_alive == "dead")
         | {id:($m.id + "/" + .id),backend:"secondmate-home",target:(.endpoint.target // "-"),
            endpoint:(if .endpoint.exists == false then "verified_absent"
                      elif .endpoint.exists == true then "verified_present" else "unverified" end),
            worker:(if .endpoint.agent_alive == "alive" then "verified_present"
                    elif .endpoint.agent_alive == "dead" then "verified_absent" else "unverified" end),
            activity:(if .endpoint.exists == false then "absent"
                      elif .endpoint.agent_alive == "dead" then "inactive" else "unverified" end),
            evidence_grade:"endpoint_only"} ]) as $unhealthy_all
  | ([ (.secondmate_current.records // [])[]
       | ([.decisions_open[]? | select(.source == "backlog" and .verb == "captain-hold")]) as $captain_holds
       | ([.holds[]? | select(.source == "backlog")]) as $backlog_holds
       | . + {
           bearings_captain_holds:$captain_holds,
           bearings_holds:(if .current.state == "captain_decision" then $backlog_holds else .holds end),
           bearings_state:(
             if .current.state == "captain_decision" then
               if ($captain_holds | length) > 0 then "captain_decision"
               elif (.active_children | length) > 0 then "active_child_work"
               elif ($backlog_holds | length) > 0 then "externally_held"
               else "unknown" end
             else .current.state end)
         } ]) as $secondmate_views
  | ([ if .secondmate_current.registry.available == false then
         {id:"(registry)",state:"unknown",doing:(.secondmate_current.registry.reason // "Registered secondmate table unavailable"),
          provenance:(.secondmate_current.registry.provenance // "registered-table"),
          freshness:(.secondmate_current.registry.freshness.status // "unavailable"),
          age_seconds:null,contradiction:false,reason:(.secondmate_current.registry.reason // "Registered secondmate table unavailable")}
       else empty end ]
     + [ $secondmate_views[]
       | {id,state:.bearings_state,
          doing:((if .bearings_state == "active_child_work" then
                    ([.active_children[] | .id + ": " + (.doing // .state)] | join("; "))
                  elif .bearings_state == "captain_decision" then
                    ([.bearings_captain_holds[] | .summary] | join("; "))
                  elif .bearings_state == "externally_held" then
                    ([.bearings_holds[] | .id + ": " + (.reason // "held")] | join("; "))
                  elif .bearings_state == "no_active_work" then "No active child work"
                  else (.current.reason // "Current home state unavailable") end) | trunc(120)),
          provenance:.provenance.selected,freshness:.freshness.status,
          age_seconds:.freshness.age_seconds,contradiction:(.contradiction // false),
          reason:(.current.reason // "-")} ]) as $secondmates_all
  | ([ .tasks[]
       | select(.kind != "secondmate")
       | select(.backlog.current_role != "program")
       | select(.backlog.current_role != "held")
       | select(effectively_working)
       | {id, kind,
        state: (if .current_state.state == "working" then "working" else .liveness.activity end),
        doing: ((if .liveness.activity != "active" then (.current_state.detail // "authoritative run active")
                 elif .liveness.output.changed then "backend output changed across samples"
                 else "cumulative CPU delta \(.liveness.cpu.delta_ms) ms (\(.liveness.cpu.rate_ms_per_minute) ms/min, \(.liveness.harness_family) baseline)" end) | trunc(90))
      } ]
     + [ $secondmate_views[]
         | select(.bearings_state == "active_child_work")
         | {id,kind:"secondmate",state:.bearings_state,
            doing:([.active_children[] | .id + ": " + (.doing // .state)] | join("; ") | trunc(90))} ]) as $in_flight_all
  | ([ .backlog.records[]
         | select(.structured and .captain_actionable == true)
         | {id,key:.id,verb:"captain-hold",
            summary:((.title + ": " + .hold_reason) | trunc(90)),owner:"(main)"} ]
     + [ (.secondmate_current.records // [])[] as $m | $m.decisions_open[]?
         | select(.source == "backlog" and .verb == "captain-hold")
         | {id:($m.id + "/" + .id),key,verb,
            summary:(((.summary // .id) + ": " + (.reason // "captain decision pending")) | trunc(90)),owner:$m.id} ]) as $decisions_all
  | ((if (.main_inventory.valid == false) then
        [{id:"(main-inventory)",
          title:((.main_inventory.reason // "main inventory invalid") | trunc(60)),
          blocked_by:"-",
          reason:"main inventory",
          owner:"(main)"}]
      else [] end)
     + [ .tasks[]
         | select(.kind != "secondmate" and .backlog.state == "in_flight"
                  and .backlog.current_role != "held" and (effectively_working | not))
         | {id,title:((.backlog.title // .id) | trunc(60)),blocked_by:"-",
            reason:("measured liveness: " + .liveness.activity + "; endpoint=" + .liveness.endpoint.presence + "; worker=" + .liveness.worker.presence | trunc(120)),owner:"(main)"} ]
     + [ .backlog.records[]
         | select(.structured and
             (.state == "queued" or
              (.state == "in_flight" and .current_role == "held")))
         | select(.captain_actionable != true)
         | select((((.body_excerpt // "") | test("SUPERSEDED|NOT REQUIRED|NOT-REQUIRED|DEFERRED"; "i")) | not))
         | {id, title:(.title | trunc(60)),
            blocked_by:((.unresolved_blocker_ids // []) | if length > 0 then join(",") else "-" end | trunc(120)),
            reason:((.hold_reason // .blocked_reason // "-") | trunc(40)),owner:"(main)"} ]
     + [ (.secondmate_current.records // [])[] as $m
         | select($m.provenance.selected == "structured-home")
         | $m.queued[]?
         | select(.captain_actionable != true)
         | {id,title:(.title | trunc(60)),
            blocked_by:((.unresolved_blocker_ids // []) | if length > 0 then join(",") else "-" end | trunc(120)),
            reason:((.hold_reason // .blocked_reason // "-") | trunc(40)),owner:$m.id} ]) as $gates_all
  | ([ .scout_reports[]
       | . as $r
       | select(($rel_ids | index($r.id)) != null)
       | {id, path} ]) as $reports_all
  | ([ $candidate_prs[] | select(.task != "-")
       | {id:.task,url,state,mergedAt,verification} ]) as $recorded_prs_all
  | . as $snap
  | (($secondmates_all | length) + ($snap.secondmate_current.truncated // 0)) as $secondmates_total
  | ([
      (if ($in_flight_all | length) > $in_flight_n then
         portfolio_bound("in_flight"; $in_flight_n; ($in_flight_all | length);
           ("rerun with FM_BEARINGS_IN_FLIGHT=" + (($in_flight_all | length) | tostring)))
       else empty end),
      (if $secondmates_total > $secondmates_n then
         portfolio_bound("secondmates"; ([($secondmates_all[:$secondmates_n])[]] | length); $secondmates_total;
           ("rerun with FM_BEARINGS_SECONDMATES=" + ($secondmates_total | tostring)
            + " and FM_SNAPSHOT_SECONDMATES=" + ($secondmates_total | tostring)))
       else empty end),
      (if ($decisions_all | length) > $decisions_n then
         portfolio_bound("decisions_open"; $decisions_n; ($decisions_all | length);
           ("rerun with FM_BEARINGS_DECISIONS=" + (($decisions_all | length) | tostring)))
       else empty end),
      (if $landed_total_count > $landed_selected_count then
         portfolio_bound((if $landed_live_rejected_count > 0 then "landed candidates" else "landed" end);
           $landed_selected_count; $landed_total_count;
           ("rerun with FM_BEARINGS_LANDED=" + ($landed_total_count | tostring)
            + " FM_BEARINGS_LANDED_PER_HOME=" + ($landed_total_count | tostring)
            + " and FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=" + ($landed_total_count | tostring)))
       else empty end),
      (if ($gates_all | length) > $gates_n then
         portfolio_bound("gates"; $gates_n; ($gates_all | length);
           ("rerun with FM_BEARINGS_GATES=" + (($gates_all | length) | tostring)))
       else empty end),
      (if ($reports_all | length) > $reports_n then
         portfolio_bound("reports"; $reports_n; ($reports_all | length);
           ("rerun with FM_BEARINGS_REPORTS=" + (($reports_all | length) | tostring)))
       else empty end),
      (if $recorded_url_total > ($recorded_prs_all[:$recorded_prs_n] | length) then
         portfolio_bound("recorded_prs"; ($recorded_prs_all[:$recorded_prs_n] | length); $recorded_url_total;
           ("rerun with FM_BEARINGS_RECORDED_PRS=" + ($recorded_url_total | tostring)))
       else empty end),
      (if ($unhealthy_all | length) > $unhealthy_n then
         portfolio_bound("unhealthy_endpoints"; $unhealthy_n; ($unhealthy_all | length);
           ("rerun with FM_BEARINGS_UNHEALTHY=" + (($unhealthy_all | length) | tostring)))
       else empty end),
      (if $include_prs == 1 and $pr_repos_total > $pr_repos_shown then
         portfolio_bound("PR repositories"; $pr_repos_shown; $pr_repos_total;
           ("rerun with FM_BEARINGS_PR_REPOS=" + ($pr_repos_total | tostring) + " --include-prs"))
       else empty end)
    ]) as $portfolio_bounds
  | {
      schema: "fm-bearings.v1",
      home: $home,
      generated: $now,
      prs: $prs,
      in_flight: $in_flight_all[:$in_flight_n],
      secondmates: $secondmates_all[:$secondmates_n],
      decisions_open: $decisions_all[:$decisions_n],
      landed: ($done | map({id, what:(.title | trunc(70)),
                            artifact:(.pr_url // .report_path // .local_note // "-"),owner:.home_id})),
      gates: $gates_all[:$gates_n],
      reports: $reports_all[:$reports_n],
      recorded_prs: $recorded_prs_all[:$recorded_prs_n]
    }
  | . + (if ($portfolio_bounds | length) > 0 then {portfolio_bounds:$portfolio_bounds} else {} end)
  | . + (if ($unhealthy_all | length) > 0 then
           {unhealthy_endpoints:$unhealthy_all[:$unhealthy_n]}
         else {} end)
  | . + {candidate_prs:$candidate_prs}
  | . + (if $include_prs == 1 then {pr_discovery:$pr_discovery} else {} end)
  | . + (if $f_bodies then {bodies:[ $snap.backlog.records[] | select(.structured and (.state == "queued" or .state == "done")) | {id, body:((.body_excerpt // .raw // "-") | trunc(200))} ]} else {} end)
  | . + (if $f_paths then {paths:[ $snap.tasks[] | {id, worktree:(.paths.worktree.path // "-"), home:(.paths.home.path // "-"), status:.paths.status_log.path, report:.paths.report.path} ]} else {} end)
  | . + (if $f_actions then {actions:[ $snap.tasks[] | {id, watch:(.actions.watch // .actions.send // "-"), steer:(.actions.steer // .actions.send // "-")} ]} else {} end)
  | . + (if $f_endpoints then {endpoints:[ $snap.tasks[] | {id, backend, target:(.endpoint.target // "-"),
      endpoint:.liveness.endpoint.presence,worker:.liveness.worker.presence,activity:.liveness.activity} ]} else {} end)
  | . + {omitted: (
      [ (if $f_bodies then empty else {surface:"backlog item bodies", reveal:"--fields bodies"} end),
        (if $f_paths then empty else {surface:"task paths", reveal:"--fields paths"} end),
        (if $f_actions then empty else {surface:"watch/steer actions", reveal:"--fields actions"} end),
        (if $f_endpoints then empty else {surface:"healthy endpoint detail", reveal:"--fields endpoints"} end),
        {surface:"full scout-report inventory", reveal:"not included in bounded core"},
        {surface:"superseded queued items", reveal:"not included in bounded core"},
        (if $per_home_capped_count > $landed_selected_count then {surface:((if $landed_live_rejected_count > 0 then "landed candidates" else "landed" end) + " showing \($landed_selected_count) of \($per_home_capped_count)" + (($landed_selection.selected | map(.home_id) | unique | map(select(. != "(main)")) | length) as $k | if $k > 0 then " (incl. \($k) secondmate home(s))" else "" end)), reveal:"bounded core"} else empty end),
        (if $landed_live_rejected_count > 0 then {surface:("selected PR completion(s) excluded from landed by live forge state: \($landed_live_rejected_count)"), reveal:"inspect candidate_prs"} else empty end),
        (if $home_cap_dropped > 0 then {surface:("landed per-home capped at \($landed_per_home_n) for \($home_cap_dropped) home(s)"), reveal:"bounded core"} else empty end),
        (if (($snap.secondmate_landed.unreadable // []) | length) > 0 then {surface:("secondmate home(s) with unreadable backlog: \(($snap.secondmate_landed.unreadable // []) | length)"), reveal:"inspect the listed secondmate home backlogs"} else empty end),
        (if (($snap.secondmate_landed.truncated // []) | length) > 0 then {surface:("secondmate home Done capped at the snapshot layer for \(($snap.secondmate_landed.truncated // []) | length) home(s)"), reveal:"bounded core"} else empty end),
        ((($snap.main_inventory.orphan_in_flight // []) | length) as $n
         | if $n > 0 then {surface:("main in-flight backlog item(s) have no child metadata: \($n)"), reveal:"inspect main data/backlog.md In flight vs state/*.meta"} else empty end),
        ((($snap.main_inventory.unstructured_current_count // 0)) as $n
         | if $n > 0 then {surface:("main unstructured current backlog row(s): \($n)"), reveal:"inspect main data/backlog.md In flight and Queued free-form rows"} else empty end),
        (if ($in_flight_all | length) > $in_flight_n then {surface:("in_flight showing \($in_flight_n) of \($in_flight_all | length)"), reveal:"bounded core"} else empty end),
        (if ($secondmates_all | length) > $secondmates_n then {surface:("secondmates showing \($secondmates_n) of \($secondmates_all | length)"), reveal:"bounded core"} else empty end),
        (if (($snap.secondmate_current.truncated // 0) > 0) then {surface:("registered secondmates omitted by snapshot bound: \($snap.secondmate_current.truncated)"), reveal:"raise FM_SNAPSHOT_SECONDMATES"} else empty end),
        (if $snap.secondmate_current.registry.input_truncated == true then {surface:"secondmate registry input truncated by bounded read", reveal:"raise FM_SNAPSHOT_REGISTRY_LINES or FM_SNAPSHOT_REGISTRY_BYTES"} else empty end),
        (if $snap.secondmate_current.registry.records_truncated == true then {surface:"secondmate registry records omitted by bounded read", reveal:"raise FM_SNAPSHOT_REGISTRY_RECORDS"} else empty end),
        (if $snap.secondmate_current.registry.available == false then {surface:("secondmate registry unavailable: " + ($snap.secondmate_current.registry.reason // "read failed")), reveal:"inspect data/secondmates.md"} else empty end),
        (([($snap.secondmate_current.records // [])[] | select(.parent_event.activity_scan.input_truncated == true or .parent_event.activity_scan.retained_truncated == true)] | length) as $n | if $n > 0 then {surface:("secondmate parent activity evidence truncated for \($n) record(s)"), reveal:"raise FM_SNAPSHOT_PARENT_ACTIVITY_LINES, FM_SNAPSHOT_PARENT_ACTIVITY_BYTES, or FM_SNAPSHOT_PARENT_ACTIVITIES"} else empty end),
        (([($snap.secondmate_current.records // [])[] | select(.parent_event.activity_scan.available == false)] | length) as $n | if $n > 0 then {surface:("secondmate parent activity evidence unavailable for \($n) record(s)"), reveal:"inspect the parent status logs"} else empty end),
        (if ($decisions_all | length) > $decisions_n then {surface:("decisions_open showing \($decisions_n) of \($decisions_all | length)"), reveal:"bounded core"} else empty end),
        (if ($gates_all | length) > $gates_n then {surface:("gates showing \($gates_n) of \($gates_all | length)"), reveal:"bounded core"} else empty end),
        (if ($reports_all | length) > $reports_n then {surface:("reports showing \($reports_n) of \($reports_all | length)"), reveal:"bounded core"} else empty end),
        (if $recorded_url_total > (.recorded_prs | length) then {surface:("recorded_prs showing \(.recorded_prs | length) of \($recorded_url_total)"), reveal:"bounded core"} else empty end),
        (if ($unhealthy_all | length) > $unhealthy_n then {surface:("unhealthy_endpoints showing \($unhealthy_n) of \($unhealthy_all | length)"), reveal:"bounded core"} else empty end),
        (if $include_prs == 1 and $pr_repos_total > $pr_repos_shown then {surface:("PR repositories showing \($pr_repos_shown) of \($pr_repos_total)"), reveal:"bounded core"} else empty end),
        (if $include_prs == 1 and $pr_rows_capped > 0 then {surface:("candidate_prs showing \($candidate_prs | length) of at least \($pr_rows_min_total); capped in \($pr_rows_capped) repo(s)"), reveal:"raise FM_BEARINGS_PR_LIMIT"} else empty end),
        (if $include_prs == 1 then empty else {surface:"additional live open-PR discovery", reveal:"--include-prs"} end) ]) }
') || { echo "fm-bearings-snapshot: projection failed" >&2; exit 1; }

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

# --- TOON renderer (output boundary; parity with the JSON model) ------------
# The model is a flat object of scalar fields plus arrays of uniform scalar
# objects, so the encoder only needs object scalars, the tabular array form
# (key[N]{fields}: + comma rows at +2 indent), and the empty-array form (key: []),
# per the TOON spec. Quoting follows the spec exactly.
TOON=$(printf '%s\n' "$MODEL" | jq -r '
  def q:
    tostring
    | if (. == "")
        or test("^\\s|\\s$")
        or (. == "true" or . == "false" or . == "null")
        or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
        or test("[:\"\\\\\\[\\]{},]")
        or test("[[:cntrl:]]")
        or test("^-")
      then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
      else . end;
  def scal:
    if . == null then "null"
    elif type == "boolean" then (if . then "true" else "false" end)
    elif type == "number" then tostring
    else q end;
  def emit($k; $v):
    if ($v | type) == "array" then
      if ($v | length) == 0 then "\($k): []"
      else
        ($v[0] | keys_unsorted) as $ks
        | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
            ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
      end
    else "\($k): " + ($v | scal)
    end;
  [ to_entries[] | emit(.key; .value) ] | join("\n")
') || { echo "fm-bearings-snapshot: TOON rendering failed" >&2; exit 1; }
printf '%s\n' "$TOON"
