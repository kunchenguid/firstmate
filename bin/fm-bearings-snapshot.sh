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
# LOCAL-ONLY by default: a normal invocation makes ZERO GitHub/network/auth calls.
# It MAY surface PR URLs already recorded locally in task meta (recorded_prs), but it
# performs no live discovery or checks. Live PR discovery/checks happen ONLY under
# --include-prs, which is the sole path that touches the network; all gh coupling
# lives in that branch and never in the canonical snapshot. The default output states
# explicitly (the prs: line and the omitted[] surfaces) what was not requested, so an
# absence is never ambiguous.
#
# The durable keyed unresolved-decision model lives in the canonical layer
# (fm-classify-lib.sh's status_open_decisions, surfaced as hints.open_decisions):
# this wrapper only aggregates that already-correct open set. A later unrelated done
# can never mask a still-open captain decision.
#
# Flags:
#   (default)        compact projection, TOON, local-only
#   --json           the same projected model as JSON (machine/debug; parity form)
#   --include-prs    ALSO do live open-PR discovery + checks (the only network path)
#   --fields <list>  opt in to dropped surfaces: bodies,paths,actions,endpoints
#   --all-reports    include the full scout-report inventory (default: relevant only)
#   --all-queued     include superseded/held queued items (default: dropped)
#   -h,--help        usage
#
# Output contract: `fm-bearings.v1`. Read-only; no locks, no mutation, no reports.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/fm-fleet-snapshot.sh"

# Bounds (overridable for tests / large fleets).
FM_BEARINGS_LANDED=${FM_BEARINGS_LANDED:-6}
FM_BEARINGS_PR_LIMIT=${FM_BEARINGS_PR_LIMIT:-20}
FM_BEARINGS_PR_TIMEOUT=${FM_BEARINGS_PR_TIMEOUT:-20}
case "$FM_BEARINGS_PR_TIMEOUT" in ''|*[!0-9]*|0) FM_BEARINGS_PR_TIMEOUT=20 ;; esac

usage() {
  cat <<'EOF'
usage: fm-bearings-snapshot.sh [--json] [--include-prs] [--fields <list>]
                               [--all-reports] [--all-queued]

Compact bearings projection over fm-fleet-snapshot.sh. TOON by default.
Default is LOCAL-ONLY (no network); --include-prs is the only path that fetches.

Default fields: schema, home, generated, prs, in_flight{id,kind,state,doing},
  decisions_open{id,key,verb,summary}, landed{id,what,artifact},
  gates{id,title,blocked_by,reason}, reports{id,path}, recorded_prs{id,url},
  unhealthy_endpoints{...} (only when non-empty), omitted{surface,reveal}.
Opt-in surfaces: --fields bodies|paths|actions|endpoints, --all-reports,
  --all-queued, --include-prs (adds candidate_prs).
EOF
}

FORMAT=toon
INCLUDE_PRS=0
ALL_REPORTS=0
ALL_QUEUED=0
FIELDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --include-prs) INCLUDE_PRS=1 ;;
    --all-reports) ALL_REPORTS=1 ;;
    --all-queued) ALL_QUEUED=1 ;;
    --fields) shift; FIELDS=${1:-} ;;
    --fields=*) FIELDS=${1#--fields=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-bearings-snapshot: jq not found" >&2; exit 1; }

SNAP=$("$FLEET" --json) || exit $?
HOME_LABEL=$(printf '%s' "$SNAP" | jq -r '.fm_home | split("/") | (.[-2:] | join("/"))')
NOW=${FM_BEARINGS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

# --- optional live PR enrichment (the ONLY network path) --------------------
PR_STATUS='not_requested (run: /bearings include PRs)'
CANDIDATE_PRS='[]'

# Parse owner/repo from an https or ssh GitHub remote/PR URL; empty if not GitHub.
repo_slug() {  # <url>
  printf '%s' "$1" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' | sed 's#\.git$##; s#/pull/.*$##; s#/$##'
}

# Bounded gh call; prints stdout, non-zero on timeout/failure. gh only.
gh_bounded() {  # <args...>
  if command -v timeout >/dev/null 2>&1; then
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 timeout "$FM_BEARINGS_PR_TIMEOUT" gh "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gtimeout "$FM_BEARINGS_PR_TIMEOUT" gh "$@"
  elif command -v perl >/dev/null 2>&1; then
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$FM_BEARINGS_PR_TIMEOUT" gh "$@"
  else
    return 124
  fi
}

if [ "$INCLUDE_PRS" = 1 ]; then
  if ! command -v gh >/dev/null 2>&1; then
    PR_STATUS='unavailable (gh not found)'
  else
    # Candidate repos: recorded pr= URLs plus live worktree origins. Deduped.
    repos=""
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      s=$(repo_slug "$u"); [ -n "$s" ] || continue
      case " $repos " in *" $s "*) : ;; *) repos="$repos $s" ;; esac
    done <<EOF
$(printf '%s' "$SNAP" | jq -r '.tasks[].pr.url // empty')
EOF
    while IFS= read -r wt; do
      [ -n "$wt" ] && [ -d "$wt" ] || continue
      u=$(git -C "$wt" remote get-url origin 2>/dev/null) || continue
      s=$(repo_slug "$u"); [ -n "$s" ] || continue
      case " $repos " in *" $s "*) : ;; *) repos="$repos $s" ;; esac
    done <<EOF
$(printf '%s' "$SNAP" | jq -r '.tasks[] | select(.kind != "secondmate") | .paths.worktree.path // empty')
EOF

    nrepos=0; npr=0; nwarn=0; rows='[]'
    for repo in $repos; do
      nrepos=$((nrepos + 1))
      out=$(gh_bounded pr list --repo "$repo" --state open --limit "$FM_BEARINGS_PR_LIMIT" \
        --json number,title,url,headRefName,reviewDecision,mergeable,statusCheckRollup 2>/dev/null) \
        || { nwarn=$((nwarn + 1)); continue; }
      [ -n "$out" ] || out='[]'
      repo_rows=$(printf '%s' "$out" | jq --arg repo "$repo" '
        [ .[] | {
          num:(.number|tostring),
          repo:$repo,
          task:(if (.headRefName // "" | startswith("fm/")) then (.headRefName | ltrimstr("fm/")) else "-" end),
          url:(.url // "-"),
          review:(.reviewDecision // "none"),
          mergeable:(.mergeable // "UNKNOWN"),
          checks:(
            (.statusCheckRollup // []) as $c
            | if ($c|length) == 0 then "none"
              elif any($c[]; (.conclusion // .state // "") as $s | ($s=="FAILURE" or $s=="ERROR" or $s=="TIMED_OUT" or $s=="CANCELLED" or $s=="ACTION_REQUIRED")) then "failing"
              elif any($c[]; ((.status // "") != "COMPLETED") and ((.state // "") != "SUCCESS")) then "pending"
              else "passing" end)
        } ]') || { nwarn=$((nwarn + 1)); continue; }
      cnt=$(printf '%s' "$repo_rows" | jq 'length')
      npr=$((npr + cnt))
      rows=$(jq -n --argjson a "$rows" --argjson b "$repo_rows" '$a + $b')
    done
    CANDIDATE_PRS=$rows
    warnnote=""
    [ "$nwarn" -gt 0 ] && warnnote="; ${nwarn} repo(s) unavailable"
    PR_STATUS="checked (${nrepos} repos, ${npr} open${warnnote})"
  fi
fi

# --- projection: canonical snapshot -> fm-bearings.v1 model (JSON) ----------
MODEL=$(printf '%s' "$SNAP" | jq \
  --arg home "$HOME_LABEL" \
  --arg now "$NOW" \
  --arg prs "$PR_STATUS" \
  --arg fields "$FIELDS" \
  --argjson landed_n "$FM_BEARINGS_LANDED" \
  --argjson include_prs "$INCLUDE_PRS" \
  --argjson all_reports "$ALL_REPORTS" \
  --argjson all_queued "$ALL_QUEUED" \
  --argjson candidate_prs "$CANDIDATE_PRS" '
  def trunc($n): if . == null then null else
    (tostring | gsub("\\s+"; " ") | if (length > $n) then (.[:$n] + "…") else . end) end;
  ($fields | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $fl
  | (($fl | index("bodies")) != null) as $f_bodies
  | (($fl | index("paths")) != null) as $f_paths
  | (($fl | index("actions")) != null) as $f_actions
  | (($fl | index("endpoints")) != null) as $f_endpoints
  | ([ .backlog.records[] | select(.state == "done" and .structured) ][:$landed_n]) as $done
  | ($done | map(.id)) as $done_ids
  | (.tasks | map(.id)) as $live_ids
  | ($live_ids + $done_ids) as $rel_ids
  | ([ .tasks[]
       | select(.endpoint.exists == false or .endpoint.agent_alive == "dead")
       | {id, backend, target:(.endpoint.target // "-"), exists:.endpoint.exists, agent:.endpoint.agent_alive} ]) as $unhealthy
  | . as $snap
  | {
      schema: "fm-bearings.v1",
      home: $home,
      generated: $now,
      prs: $prs,
      in_flight: [ .tasks[] | {
        id, kind,
        state: .current_state.state,
        doing: ((.current_state.detail // "") as $d
                | (if $d != "" then $d else (.hints.last_event_text // "") end) | trunc(90))
      } ],
      decisions_open: [ .tasks[] as $t | ($t.hints.open_decisions // [])[]
                        | {id:$t.id, key, verb, summary:(.summary | trunc(90))} ],
      landed: ($done | map({id, what:(.title | trunc(70)),
                            artifact:(.pr_url // .report_path // .local_note // "-")})),
      gates: [ .backlog.records[]
               | select(.state == "queued" and .structured)
               | select(($all_queued == 1)
                        or (((.body_excerpt // "") | test("SUPERSEDED|NOT REQUIRED|NOT-REQUIRED|DEFERRED"; "i")) | not))
               | {id, title:(.title | trunc(60)), blocked_by:(.blocked_by // "-"),
                  reason:((.blocked_reason // "-") | trunc(40))} ],
      reports: [ .scout_reports[]
                 | . as $r
                 | select(($all_reports == 1) or (($rel_ids | index($r.id)) != null))
                 | {id, path} ],
      recorded_prs: [ .tasks[] | select(.pr.url != null and .pr.source == "meta") | {id, url:.pr.url} ]
    }
  | . + (if ($unhealthy | length) > 0 then {unhealthy_endpoints:$unhealthy} else {} end)
  | . + (if $include_prs == 1 then {candidate_prs:$candidate_prs} else {} end)
  | . + (if $f_bodies then {bodies:[ $snap.backlog.records[] | select(.structured and (.state == "queued" or .state == "done")) | {id, body:((.body_excerpt // .raw // "-") | trunc(200))} ]} else {} end)
  | . + (if $f_paths then {paths:[ $snap.tasks[] | {id, worktree:(.paths.worktree.path // "-"), home:(.paths.home.path // "-"), status:.paths.status_log.path, report:.paths.report.path} ]} else {} end)
  | . + (if $f_actions then {actions:[ $snap.tasks[] | {id, watch:(.actions.watch // .actions.send // "-"), steer:(.actions.steer // .actions.send // "-")} ]} else {} end)
  | . + (if $f_endpoints then {endpoints:[ $snap.tasks[] | {id, backend, target:(.endpoint.target // "-"), exists:.endpoint.exists, agent:.endpoint.agent_alive} ]} else {} end)
  | . + {omitted: (
      [ (if $f_bodies then empty else {surface:"backlog item bodies", reveal:"--fields bodies"} end),
        (if $f_paths then empty else {surface:"task paths", reveal:"--fields paths"} end),
        (if $f_actions then empty else {surface:"watch/steer actions", reveal:"--fields actions"} end),
        (if $f_endpoints then empty else {surface:"healthy endpoint detail", reveal:"--fields endpoints"} end),
        (if $all_reports == 1 then empty else {surface:"full scout-report inventory", reveal:"--all-reports"} end),
        (if $all_queued == 1 then empty else {surface:"superseded/held queued items", reveal:"--all-queued"} end),
        (if $include_prs == 1 then empty else {surface:"live PR discovery + checks", reveal:"--include-prs"} end) ]) }
')

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

# --- TOON renderer (output boundary; parity with the JSON model) ------------
# The model is a flat object of scalar fields plus arrays of uniform scalar
# objects, so the encoder only needs object scalars, the tabular array form
# (key[N]{fields}: + comma rows at +2 indent), and the empty-array form (key: []),
# per the TOON spec. Quoting follows the spec exactly.
printf '%s\n' "$MODEL" | jq -r '
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
'
