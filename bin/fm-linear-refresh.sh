#!/usr/bin/env bash
# Refresh the Linear mirror of data/backlog.md IN PLACE.
#
# The captain's 2026-08-02 decision keeps data/backlog.md authoritative and makes
# Linear a browsable view regenerated on request. This is that regeneration, and
# it is repeatable: a second run updates the issues the first run created instead
# of doubling the board.
#
# Usage: fm-linear-refresh.sh [--dry-run] [--team <KEY>] [--backlog <file>] [--archive <file>]
#
# Reconciliation is joined on the FIRST LINE of each Linear description,
# `firstmate: <task-id>` (see bin/fm-linear-lib.sh). For every id:
#   in the backlog and in Linear  -> UPDATE that issue (never create a second one)
#   in the backlog only           -> CREATE it
#   in Linear only                -> REPORT it as retired, and change nothing.
# Deleting or archiving the captain's issues is never this tool's decision, so
# the retired list is output, not an action.
#
# Completed work moves to the team's Done status and carries its PR (as a Linear
# link attachment) or its scout report path, so the board can answer "what has
# been built and confirmed" - which data/backlog.md cannot, because it prunes
# Done to the configured recent few. That is also why data/done-archive.md is
# read by default alongside the backlog: the pruned entries live there.
#
# What this NEVER writes: priority, labels, project, cycle, estimate, assignee,
# or the status of anything that is not newly done. Those are the captain's, and
# reprioritising in Linear must survive a refresh.
#
# Exit codes: 0 refreshed (or inert because Linear is not configured), 2 usage or
# unresolvable team, 3 Linear unreachable, 4 some operations failed. Nothing here
# is on a PR's path, so a non-zero exit reports a refresh that did not fully
# happen; it never gates delivery.
#
# GraphQL documents below are single-quoted on purpose: $id and friends inside
# them are GraphQL variables, not shell expansions.
# shellcheck disable=SC2016
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME

DRY=
TEAM_KEY=
BACKLOG="$FM_HOME/data/backlog.md"
ARCHIVE="$FM_HOME/data/done-archive.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1; shift ;;
    --team) TEAM_KEY=${2:-}; shift 2 ;;
    --backlog) BACKLOG=${2:-}; shift 2 ;;
    --archive) ARCHIVE=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "fm-linear-refresh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=bin/fm-linear-lib.sh
. "$FM_ROOT/bin/fm-linear-lib.sh"
fml_load_config
[ -n "$TEAM_KEY" ] || TEAM_KEY=$FML_TEAM

if ! fml_available; then
  echo "linear: $(fml_unavailable_reason); refresh did not run"
  exit 0
fi
if [ ! -f "$BACKLOG" ]; then
  echo "fm-linear-refresh: no backlog at $BACKLOG" >&2
  exit 2
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-linear-refresh.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'rm -rf "$TMP"; exit 143' HUP INT TERM

# --- what the backlog says --------------------------------------------------

"$FM_ROOT/bin/fm-backlog-tsv.sh" "$BACKLOG" "$ARCHIVE" > "$TMP/backlog.tsv"
backlog_n=$(wc -l < "$TMP/backlog.tsv" | tr -d '[:space:]')

# --- what Linear already holds ----------------------------------------------
#
# Every issue whose description carries the marker, workspace-wide, paginated.
# The exact first-line match happens client-side (FML_ROWS_FILTER), so an issue
# that merely mentions a task id in its body is never mistaken for the mirror.

: > "$TMP/linear.tsv"
cursor=null
page=0
while :; do
  page=$((page + 1))
  vars=$(jq -cn --arg needle 'firstmate: ' --argjson after "$cursor" '{needle:$needle, after:$after}')
  if ! fml_graphql 'query fmList($needle: String!, $after: String) {
    issues(filter: { description: { contains: $needle } }, first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { id identifier url title description state { name type } team { id key } }
    }
  }' "$vars" "$TMP/page.json"; then
    # Same fallback as the lookup path: the description filter is an
    # optimisation, so a schema change degrades to a full scan, not to silence.
    if ! fml_graphql 'query fmListAll($after: String) {
      issues(first: 100, after: $after, orderBy: updatedAt) {
        pageInfo { hasNextPage endCursor }
        nodes { id identifier url title description state { name type } team { id key } }
      }
    }' "$vars" "$TMP/page.json"; then
      echo "linear: could not read the existing issues (Linear unreachable, unauthenticated, or too slow); refresh did not run" >&2
      exit 3
    fi
  fi
  jq -r '
    def marker_id:
      (. // "") | split("\n")[0] | gsub("`"; "") | gsub("^\\s+|\\s+$"; "")
      | if startswith("firstmate:") then (.[10:] | gsub("^\\s+|\\s+$"; "")) else "" end
      | if test("\\s") then "" else . end;
    .data.issues.nodes[]
    | (.description | marker_id) as $id
    | select($id != "")
    | [$id, .identifier, .id, .url, (.state.type // ""), (.team.id // ""), (.team.key // ""), .title, ((.description // "") | @base64)]
    | @tsv
  ' "$TMP/page.json" >> "$TMP/linear.tsv"
  [ "$(jq -r '.data.issues.pageInfo.hasNextPage' "$TMP/page.json")" = "true" ] || break
  cursor=$(jq -c '.data.issues.pageInfo.endCursor' "$TMP/page.json")
  [ "$page" -lt 50 ] || { echo "linear: stopped paginating after 50 pages" >&2; break; }
done

# Scope to one team when asked, so a workspace mirroring several backlogs stays
# separable. Without a key, every mirrored issue is in scope.
if [ -n "$TEAM_KEY" ]; then
  awk -F'\t' -v k="$TEAM_KEY" '$7 == k' "$TMP/linear.tsv" > "$TMP/scoped.tsv" || true
  mv "$TMP/scoped.tsv" "$TMP/linear.tsv"
fi
linear_n=$(wc -l < "$TMP/linear.tsv" | tr -d '[:space:]')

# --- team and the Done status ------------------------------------------------
#
# A create needs a team id. Prefer the configured key; otherwise infer it from
# the issues the mirror already made, which is exactly right for a refresh.

TEAM_ID=
DONE_STATE=
if [ -n "$TEAM_KEY" ]; then
  vars=$(jq -cn --arg k "$TEAM_KEY" '{k:$k}')
  if fml_graphql 'query fmTeam($k: String!) {
    teams(filter: { key: { eq: $k } }, first: 1) {
      nodes { id key states(first: 100) { nodes { id name type position } } }
    }
  }' "$vars" "$TMP/team.json"; then
    TEAM_ID=$(jq -r '.data.teams.nodes[0].id // ""' "$TMP/team.json")
    DONE_STATE=$(jq -r '
      [.data.teams.nodes[0].states.nodes[]? | select(.type == "completed")]
      | (map(select(.name == "Done")) + sort_by(.position))[0].id // ""
    ' "$TMP/team.json")
  fi
fi
if [ -z "$TEAM_ID" ]; then
  TEAM_ID=$(awk -F'\t' 'NR==1 {print $6}' "$TMP/linear.tsv")
fi
if [ -z "$DONE_STATE" ] && [ -n "$TEAM_ID" ]; then
  vars=$(jq -cn --arg id "$TEAM_ID" '{id:$id}')
  if fml_graphql 'query fmTeamById($id: String!) {
    team(id: $id) { id key states(first: 100) { nodes { id name type position } } }
  }' "$vars" "$TMP/team2.json"; then
    DONE_STATE=$(jq -r '
      [.data.team.states.nodes[]? | select(.type == "completed")]
      | (map(select(.name == "Done")) + sort_by(.position))[0].id // ""
    ' "$TMP/team2.json")
  fi
fi

# --- compose one issue's title and description -------------------------------

# Backlog note bodies are terminal text: ASCII diagrams, aligned tables, and
# indented blocks whose whitespace carries meaning. The first mirror run had to
# repair a formatting corruption Linear's Markdown parser introduced, so the
# default here emits the body verbatim inside a fenced code block, which cannot
# be reflowed or mangled. Set LINEAR_BODY_STYLE=markdown to emit it as Markdown
# instead, accepting that risk in exchange for richer rendering.
BODY_STYLE=${LINEAR_BODY_STYLE:-preserve}

# A content fingerprint written into the description as an HTML comment. It is
# what makes refresh convergent: an issue already carrying the fingerprint for
# the current backlog content is left completely alone, so a second refresh is a
# genuine no-op and a hand-edit the captain made is not overwritten every run.
fingerprint() {
  printf '%s\037%s\037%s\037%s\037%s\037%s' "$1" "$2" "$3" "$4" "$5" "$BODY_STYLE" \
    | sha256sum | cut -c1-16
}

compose_description() {
  local id=$1 blocked=$2 body=$3 link=$4 fp=$5 out=$6
  {
    printf '`firstmate: %s`\n' "$id"
    if [ -n "$blocked" ]; then
      printf '\n**Blocked by:** %s\n' "${blocked//,/, }"
    fi
    if [ -n "$link" ]; then
      printf '\n**Delivered:** %s\n' "$link"
    fi
    if [ -n "$body" ]; then
      printf '\n'
      if [ "$BODY_STYLE" = markdown ]; then
        printf '%b\n' "$body"
      else
        printf '```\n'
        printf '%b\n' "$body"
        printf '```\n'
      fi
    fi
    printf '\n<!-- firstmate-sync: %s -->\n' "$fp"
  } > "$out"
}

created=0; updated=0; unchanged=0; done_moved=0; attached=0; failed=0
: > "$TMP/retired.txt"

report() { printf '  %-9s %-12s %s\n' "$1" "$2" "$3"; }

# --- reconcile ---------------------------------------------------------------

# Split one TSV row into the six named fields. This must NOT use
# `IFS=$'\t' read`: tab is IFS whitespace, so bash collapses runs of it and an
# EMPTY middle field (an item with no recorded link but a blocked-by) silently
# shifts every later column one to the left. That corrupts real issues rather
# than failing loudly, so the split is done by exact parameter expansion.
split_row() {
  local rest=$1
  state=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  id=${rest%%$'\t'*};    rest=${rest#*$'\t'}
  title=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  link=${rest%%$'\t'*};  rest=${rest#*$'\t'}
  blocked=${rest%%$'\t'*}
  body=${rest#*$'\t'}
}

while IFS= read -r row; do
  case "$row" in *$'\t'*) ;; *) continue ;; esac
  split_row "$row"
  [ -n "$id" ] || continue
  fp=$(fingerprint "$state" "$id" "$title" "$link" "$blocked$body")
  compose_description "$id" "$blocked" "$body" "$link" "$fp" "$TMP/desc"
  desc=$(cat "$TMP/desc")
  existing=$(awk -F'\t' -v id="$id" '$1 == id {print; exit}' "$TMP/linear.tsv")

  if [ -z "$existing" ]; then
    if [ -z "$TEAM_ID" ]; then
      report "SKIP" "$id" "would create, but no team could be resolved (set LINEAR_TEAM_KEY or pass --team)"
      failed=$((failed + 1))
      continue
    fi
    if [ -n "$DRY" ]; then
      report "create" "$id" "$title"
      created=$((created + 1))
      continue
    fi
    vars=$(jq -cn --arg t "$TEAM_ID" --arg ti "$title" --arg d "$desc" '{t:$t, ti:$ti, d:$d}')
    if fml_graphql 'mutation fmCreate($t: String!, $ti: String!, $d: String!) {
      issueCreate(input: { teamId: $t, title: $ti, description: $d }) {
        success issue { id identifier }
      }
    }' "$vars" "$TMP/created.json"; then
      new_ident=$(jq -r '.data.issueCreate.issue.identifier // ""' "$TMP/created.json")
      new_id=$(jq -r '.data.issueCreate.issue.id // ""' "$TMP/created.json")
      report "created" "${new_ident:-?}" "$id"
      created=$((created + 1))
      existing="$id	$new_ident	$new_id			$TEAM_ID	$TEAM_KEY"
      cur_state_type=""
    else
      report "FAILED" "$id" "create rejected by Linear"
      failed=$((failed + 1))
      continue
    fi
  else
    ident=$(printf '%s' "$existing" | cut -f2)
    issue_uuid=$(printf '%s' "$existing" | cut -f3)
    cur_state_type=$(printf '%s' "$existing" | cut -f5)
    cur_title=$(printf '%s' "$existing" | cut -f8)
    cur_desc=$(printf '%s' "$existing" | cut -f9 | base64 -d 2>/dev/null || true)
    if [ "$cur_title" = "$title" ] && case "$cur_desc" in *"firstmate-sync: $fp"*) true ;; *) false ;; esac; then
      unchanged=$((unchanged + 1))
    elif [ -n "$DRY" ]; then
      report "update" "$ident" "$id"
      updated=$((updated + 1))
    else
      vars=$(jq -cn --arg i "$issue_uuid" --arg ti "$title" --arg d "$desc" '{i:$i, ti:$ti, d:$d}')
      if fml_graphql 'mutation fmUpdate($i: String!, $ti: String!, $d: String!) {
        issueUpdate(id: $i, input: { title: $ti, description: $d }) { success }
      }' "$vars" "$TMP/updated.json"; then
        report "updated" "$ident" "$id"
        updated=$((updated + 1))
      else
        report "FAILED" "$ident" "update rejected by Linear"
        failed=$((failed + 1))
      fi
    fi
  fi

  ident=$(printf '%s' "$existing" | cut -f2)
  issue_uuid=$(printf '%s' "$existing" | cut -f3)
  [ -n "$issue_uuid" ] || continue

  # Completed work: move to Done once, and carry the PR as a link attachment.
  # Only a not-yet-completed issue is transitioned, so a status the captain set
  # by hand on anything still in flight is never touched.
  if [ "$state" = "done" ]; then
    if [ "$cur_state_type" != completed ]; then
      if [ -z "$DONE_STATE" ]; then
        report "SKIP" "$ident" "is done in the backlog but the team has no completed status"
        failed=$((failed + 1))
      elif [ -n "$DRY" ]; then
        report "->done" "$ident" "$id"
        done_moved=$((done_moved + 1))
      else
        vars=$(jq -cn --arg i "$issue_uuid" --arg s "$DONE_STATE" '{i:$i, s:$s}')
        if fml_graphql 'mutation fmState($i: String!, $s: String!) {
          issueUpdate(id: $i, input: { stateId: $s }) { success }
        }' "$vars" "$TMP/state.json"; then
          report "->done" "$ident" "$id"
          done_moved=$((done_moved + 1))
        else
          report "FAILED" "$ident" "Done transition rejected by Linear"
          failed=$((failed + 1))
        fi
      fi
    fi
    case "$link" in
      http://*|https://*)
        if [ -n "$DRY" ]; then
          attached=$((attached + 1))
        else
          # attachmentLinkURL is keyed on (issue, url), so re-running the refresh
          # updates the same attachment instead of stacking duplicates.
          vars=$(jq -cn --arg i "$issue_uuid" --arg u "$link" --arg t "Pull request" '{i:$i, u:$u, t:$t}')
          if fml_graphql 'mutation fmAttach($i: String!, $u: String!, $t: String!) {
            attachmentLinkURL(issueId: $i, url: $u, title: $t) { success }
          }' "$vars" "$TMP/attach.json" \
            || fml_graphql 'mutation fmAttachCreate($i: String!, $u: String!, $t: String!) {
            attachmentCreate(input: { issueId: $i, url: $u, title: $t }) { success }
          }' "$vars" "$TMP/attach.json"; then
            attached=$((attached + 1))
          else
            report "FAILED" "$ident" "could not attach $link"
            failed=$((failed + 1))
          fi
        fi
        ;;
    esac
  fi
done < "$TMP/backlog.tsv"

# --- retired ids: reported, never deleted ------------------------------------

while IFS= read -r lrow; do
  lid=${lrow%%$'\t'*}
  lident=${lrow#*$'\t'}; lident=${lident%%$'\t'*}
  [ -n "$lid" ] || continue
  awk -F'\t' -v id="$lid" '$2 == id {found=1} END {exit !found}' "$TMP/backlog.tsv" && continue
  printf '  %-12s %s\n' "$lident" "$lid" >> "$TMP/retired.txt"
done < "$TMP/linear.tsv"

# --- summary -----------------------------------------------------------------

echo
printf 'linear refresh%s: %s backlog items, %s mirrored issues%s\n' \
  "${DRY:+ (dry run)}" "$backlog_n" "$linear_n" "${TEAM_KEY:+ in team $TEAM_KEY}"
printf '  created %s, updated %s, unchanged %s, moved to Done %s, PR links %s, failed %s\n' \
  "$created" "$updated" "$unchanged" "$done_moved" "$attached" "$failed"
if [ -s "$TMP/retired.txt" ]; then
  printf '\n  no longer in the backlog (%s) - REPORTED ONLY, nothing was deleted:\n' \
    "$(wc -l < "$TMP/retired.txt" | tr -d '[:space:]')"
  cat "$TMP/retired.txt"
fi

[ "$failed" = 0 ] || exit 4
