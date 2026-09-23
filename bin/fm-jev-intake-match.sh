#!/usr/bin/env bash
# fm-jev-intake-match.sh - match a free-text captain reference to its record.
#
# Usage:
#   fm-jev-intake-match.sh <reference text...>
#
# The positional reference is the query: one line of at most 300 characters.
# A longer or multi-line reference is refused with one line and exit 2.
#
# Resolves a loose reference such as "the wiki plan I had in one prompt" to
# the backlog items and task records it most likely means, so intake does not
# have to grep the backlog and every data/<id>/ record by hand. Advisory only:
# it never opens, dispatches, transitions, or edits anything.
#
# Candidates (no model call): this home's backlog ids and titles from
# `fm-tasks-axi.sh list` and `list --state done` (five-second timeout each),
# plus every data/<id>/ directory holding report.md or brief.md, titled by that
# file's first `# ` heading (report.md wins; a brief's generic scaffold heading
# such as "Task" leaves the record titled by its backlog entry or id alone).
# One id seen in both places is one candidate. Each candidate gets a keyword
# score: the number of distinct reference words (three or more characters,
# common English and German filler dropped) found in its lowercased id plus
# title. Ties go to the record whose selected report.md or brief.md changed most
# recently first, then backlog-only items in listing order. The bounded list
# is the 24 best, topped up with unscored candidates in that same order when
# fewer than 24 score.
#
# What Jev sees (one Choice call through bin/fm-jev-lib.sh): the one-line
# reference, then candidate ids as choices with their title and backlog state
# as criteria, plus `none?` for no candidate, which cannot be a valid id.
# Titles are sanitized by fm_jev_compact_state and
# cut to 80 characters; an id that sanitization would change is dropped. File
# and task bodies never leave the machine: only the reference, ids, titles,
# and backlog states do. JEV_TIMEOUT comes from the environment or
# $FM_HOME/.env, else 5 seconds.
#
# Related tasks (no model call): for every shown candidate that is a
# data/<id> record, backlog items whose body names that record id or path as a
# whole token are listed under it, for example a plan's phase tasks. They come
# from one timed `fm-tasks-axi.sh list --fields body` per open and done listing,
# sit outside the five-candidate cap, and are capped at 12 lines.
#
# Ranking: when the chosen id is an offered candidate at or above the library
# confidence floor (JEV_CONFIDENCE_FLOOR, default 0.7), candidates are ranked
# by the Choice probabilities, or the single pick when probabilities are
# absent or malformed. A valid probability map prints only candidates with
# positive probability. Probability keys must be offered candidate ids or
# `none?`; at least one candidate must have positive mass, or output uses the
# keyword ranking. No key, a failed call, the `none?` choice, or low confidence
# also produces a keyword ranking with a reason.
#
# Output (stdout), at most five candidates:
#   jev-intake-match:
#     ranking: jev | keyword
#     fallback: none | off | error | low-confidence | no-match | no-candidates |
#               no-candidate-probability | backlog-error | jq-missing
#     source-error: backlog listing failed for <open, done> (only on failure)
#     confidence: <Jev's confidence in its pick, or empty>
#     candidates:
#       1. <id> confidence=<p> state=<backlog state or -> record=<path or -> title=<title>
#     related:
#       - <record id> -> <backlog id> state=<state> title=<title>
#     related-source-error: related task listing failed for <open, done>
# The keyword ranking prints score=<matched>/<reference words> in place of
# confidence and lists only candidates that matched; `candidates: none` when
# nothing did. A failed backlog listing is named in `source-error` and prevents
# Jev from ranking an incomplete offer. `related:` appears only when a shown
# record has related tasks.
# Exit 0 except usage (exit 2), so intake is never blocked.
#
# Log: one JSONL object per attempted Jev call appended to
# ${FM_STATE_OVERRIDE:-$FM_HOME/state}/jev-intake-match.jsonl with
# purpose=intake-match, advisory=true, the reference's length and SHA-256 (the
# reference text itself is never stored), offered ids, choice, confidence,
# ranked ids, ranking, fallback, route, http, latency_ms, decide_code, and ts.
# Secrets follow fm_jev_log_call redaction.
#
# Environment: FM_HOME, FM_DATA_OVERRIDE (the data directory, as
# bin/fm-tasks-axi.sh resolves it), FM_STATE_OVERRIDE, plus the Jev library
# keys and JEV_* settings documented in bin/fm-jev-lib.sh. This script does
# not roll its own HTTP.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'jev-intake-match: %s\n' "$1" >&2
  exit 2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') die "usage: fm-jev-intake-match.sh <reference text...>" ;;
  -*) die "unknown option: $1" ;;
  *) REFERENCE="$*" ;;
esac
case "$REFERENCE" in
  *$'\n'*|*$'\r'*) die "reference must be one line" ;;
esac
[ "${#REFERENCE}" -le 300 ] || die "reference is ${#REFERENCE} characters; the limit is 300"
REFERENCE=${REFERENCE//$'\t'/ }
[ -n "${REFERENCE// /}" ] || die "empty reference"

DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG_PATH="$STATE_DIR/jev-intake-match.jsonl"
CANDIDATE_MAX=24
SHOW_MAX=5
TITLE_MAX=80
LIST_TIMEOUT=5
JEV_TIMEOUT=${JEV_TIMEOUT:-$(fmx_env_get JEV_TIMEOUT "$FM_HOME/.env")}
JEV_TIMEOUT=${JEV_TIMEOUT:-5}
export JEV_TIMEOUT
RELATED_MAX=12
BACKLOG_ROWS=
BACKLOG_FAILURES=
RELATED_ROWS=
RELATED_FAILURES=

# Reference words: lowercase ASCII runs of three or more characters, filler
# dropped, each word once.
reference_words() {
  printf '%s' "$REFERENCE" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c '[:lower:][:digit:]' '\n' | awk '
    BEGIN {
      n = split("the and for with that this which what our had have has was were you your can could " \
        "get got let one two into from about some any all out its are not but did does please " \
        "der die das und ein eine mit von fuer auf ist wir unser unsere hatte haben", w, " ")
      for (i = 1; i <= n; i++) stop[w[i]] = 1
    }
    length($0) >= 3 && !($0 in stop) && !seen[$0]++ { print }
  '
}

# Backlog rows as id<TAB>state<TAB>title, open items first, then Done.
backlog_rows() {
  local out state_args listing_name parsed
  for state_args in '' '--state done'; do
    listing_name=open
    [ "$state_args" != '--state done' ] || listing_name='done'
    # shellcheck disable=SC2086 # state_args is a fixed flag pair or empty
    if ! out=$(fm_run_timed "$LIST_TIMEOUT" "$SCRIPT_DIR/fm-tasks-axi.sh" list $state_args 2>/dev/null); then
      BACKLOG_FAILURES="${BACKLOG_FAILURES:+$BACKLOG_FAILURES, }$listing_name"
      continue
    fi
    parsed=$(printf '%s\n' "$out" | awk '
      /^tasks\[/ { p = 1; next }
      p && /^[[:space:]]/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        n = split(line, parts, ",")
        if (n < 5) next
        title = parts[5]
        for (i = 6; i <= n; i++) title = title "," parts[i]
        sub(/\\n.*$/, "", title)
        gsub(/^"|"$/, "", title)
        printf "%s\t%s\t%s\n", parts[1], parts[2], title
        next
      }
      p { p = 0 }
    ')
    [ -z "$parsed" ] || BACKLOG_ROWS="${BACKLOG_ROWS}${parsed}"$'\n'
  done
}

# Task records as id<TAB>path<TAB>heading, most recently changed first. One awk
# pass reads each file only up to its first heading.
record_rows() {
  local dir paths=() sorted_paths=()
  [ -d "$DATA_DIR" ] || return 0
  for dir in "$DATA_DIR"/*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    if [ -f "$dir/report.md" ] && [ ! -L "$dir/report.md" ]; then
      paths+=("$dir/report.md")
    elif [ -f "$dir/brief.md" ] && [ ! -L "$dir/brief.md" ]; then
      paths+=("$dir/brief.md")
    fi
  done
  [ "${#paths[@]}" -gt 0 ] || return 0
  # shellcheck disable=SC2012 # ls -t orders the selected record files by mtime
  while IFS= read -r dir; do sorted_paths+=("$dir"); done < <(ls -t "${paths[@]}" 2>/dev/null)
  [ "${#sorted_paths[@]}" -gt 0 ] || return 0
  awk '
    function emit(file, h,    id) {
      id = file
      sub(/\/[^\/]*$/, "", id)
      sub(/^.*\//, "", id)
      printf "%s\t%s\t%s\n", id, file, h
    }
    FNR == 1 {
      if (prev != "" && !found) emit(prev, "")
      prev = FILENAME
      found = 0
    }
    /^# / {
      h = $0
      sub(/^# +/, "", h)
      if (h ~ /^(Task|Current worker role contract|Setup|Brief)$/) h = ""
      emit(FILENAME, h)
      found = 1
      nextfile
    }
    END { if (prev != "" && !found) emit(prev, "") }
  ' "${sorted_paths[@]}" 2>/dev/null
}

# Merge both sources and score: prints score<TAB>order<TAB>id<TAB>state<TAB>path<TAB>title
# for every candidate, best first.
scored_candidates() {
  local words=$1
  {
    printf '%s\n' "$BACKLOG_ROWS" | awk 'NF { print "B\t" $0 }'
    record_rows | awk '{ print "R\t" $0 }'
  } | awk -F '\t' -v words="$(printf '%s' "$words" | tr '\n' ' ')" '
    BEGIN { nw = split(words, w, " ") }
    {
      id = $2
      if (id == "" || id !~ /^[A-Za-z0-9._-]+$/) next
      if (!(id in order)) { order[id] = ++n; ids[n] = id; state[id] = "-"; path[id] = "-"; title[id] = "" }
      if ($1 == "B") {
        if (state[id] == "-") state[id] = $3
        if (btitle[id] == "") btitle[id] = $4
      } else {
        if (!(id in rorder)) rorder[id] = ++nr
        path[id] = $3
        if ($4 != "") title[id] = $4
      }
    }
    END {
      for (k = 1; k <= n; k++) {
        id = ids[k]
        t = (title[id] != "") ? title[id] : btitle[id]
        hay = tolower(id " " t)
        s = 0
        for (i = 1; i <= nw; i++) if (w[i] != "" && index(hay, w[i]) > 0) s++
        # Tie order: records by recency, then backlog-only items by listing order.
        o = (id in rorder) ? rorder[id] : 1000000 + order[id]
        printf "%d\t%d\t%s\t%s\t%s\t%s\n", s, o, id, state[id], path[id], t
      }
    }
  ' | sort -t "$(printf '\t')" -k1,1nr -k2,2n
}

emit_header() {
  printf 'jev-intake-match:\n  ranking: %s\n  fallback: %s\n  confidence: %s\n' "$1" "$2" "$3"
  [ -z "$BACKLOG_FAILURES" ] || printf '  source-error: backlog listing failed for %s\n' "$BACKLOG_FAILURES"
}

# Keyword ranking over the scored candidates: only matched ones, best first.
emit_keyword() {
  local fallback=$1 confidence=$2 nwords rows
  nwords=$(printf '%s\n' "$WORDS" | grep -c .)
  rows=$(printf '%s\n' "$SCORED" | awk -F '\t' '$1 > 0' | head -n "$SHOW_MAX")
  emit_header keyword "$fallback" "$confidence"
  if [ -z "$rows" ]; then
    printf '  candidates: none\n'
    return 0
  fi
  printf '  candidates:\n'
  printf '%s\n' "$rows" | awk -F '\t' -v nw="$nwords" \
    '{ printf "    %d. %s score=%d/%d state=%s record=%s title=%s\n", NR, $3, $1, nw, $4, $5, $6 }'
  emit_related "$(printf '%s\n' "$rows" | awk -F '\t' '{ printf "%s\t%s\n", $3, $5 }')"
}

# related_tasks <record-id...>: "<record id>\t<backlog id>" for every backlog
# item whose body contains one of the given record ids as a whole token, never
# the record's own backlog entry, at most RELATED_MAX lines.
related_tasks() {
  local out state_args listing_name parsed
  [ $# -gt 0 ] || return 0
  RELATED_ROWS=
  RELATED_FAILURES=
  for state_args in '' '--state done'; do
    listing_name=open
    [ "$state_args" != '--state done' ] || listing_name='done'
    # shellcheck disable=SC2086 # state_args is a fixed flag pair or empty
    if ! out=$(fm_run_timed "$LIST_TIMEOUT" "$SCRIPT_DIR/fm-tasks-axi.sh" list $state_args --fields body 2>/dev/null); then
      RELATED_FAILURES="${RELATED_FAILURES:+$RELATED_FAILURES, }$listing_name"
      continue
    fi
    parsed=$(printf '%s\n' "$out" | awk -v recs="$*" '
      function csv_field(s, wanted,    i, c, field, value, quoted) {
        field = 1
        value = ""
        quoted = 0
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (quoted) {
            if (c == "\"") {
              if (substr(s, i + 1, 1) == "\"") { value = value "\""; i++ }
              else quoted = 0
            } else value = value c
          } else if (c == "\"") quoted = 1
          else if (c == ",") {
            if (field == wanted) return value
            field++
            value = ""
          } else value = value c
        }
        return (field == wanted) ? value : ""
      }
      function whole_token(text, token,    at, before, suffix) {
        while ((at = index(text, token)) > 0) {
          before = (at == 1) ? "" : substr(text, at - 1, 1)
          suffix = substr(text, at + length(token))
          if (match(suffix, /^[A-Za-z0-9._-]+/)) suffix = substr(suffix, 1, RLENGTH)
          else suffix = ""
          sub(/\.+$/, "", suffix)
          if ((before == "" || before !~ /[A-Za-z0-9._-]/) && suffix == "") return 1
          text = substr(text, at + length(token))
        }
        return 0
      }
      /^tasks\[/ {
        marker = index($0, "]{")
        if (!marker) next
        columns = substr($0, marker + 2)
        sub(/}:$/, "", columns)
        count = split(columns, names, ",")
        body_index = 0
        for (i = 1; i <= count; i++) if (names[i] == "body") body_index = i
        p = body_index > 0
        next
      }
      p && /^[[:space:]]/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        id = csv_field(line, 1)
        body = csv_field(line, body_index)
        for (i = 1; i <= n; i++) {
          if (id != r[i] && whole_token(body, r[i])) printf "%s\t%s\n", r[i], id
        }
        next
      }
      p { p = 0 }
      BEGIN { n = split(recs, r, " ") }
    ')
    [ -z "$parsed" ] || RELATED_ROWS="${RELATED_ROWS}${parsed}"$'\n'
  done
  RELATED_ROWS=$(printf '%s\n' "$RELATED_ROWS" | awk '!seen[$0]++' | head -n "$RELATED_MAX")
}

# emit_related <shown-rows>: rows are id<TAB>path, as shown in the ranking.
emit_related() {
  local shown=$1 records rows
  records=$(printf '%s\n' "$shown" | awk -F '\t' '$2 != "-" && $2 != "" { print $1 }')
  [ -n "$records" ] || return 0
  # shellcheck disable=SC2086 # record ids are [A-Za-z0-9._-]+ by construction
  related_tasks $records
  rows=$RELATED_ROWS
  if [ -n "$rows" ]; then
    printf '  related:\n'
    printf '%s\n' "$rows" | while IFS=$(printf '\t') read -r rec task; do
      printf '%s\n' "$SCORED" | awk -F '\t' -v rec="$rec" -v task="$task" '
        $3 == task { printf "    - %s -> %s state=%s title=%s\n", rec, task, $4, $6; found = 1; exit }
        END { if (!found) printf "    - %s -> %s\n", rec, task }
      '
    done
  fi
  [ -z "$RELATED_FAILURES" ] || printf '  related-source-error: related task listing failed for %s\n' "$RELATED_FAILURES"
}

backlog_rows
WORDS=$(reference_words)
SCORED=$(scored_candidates "$WORDS")

if ! command -v jq >/dev/null 2>&1; then
  emit_keyword jq-missing ''
  exit 0
fi

if [ -n "$BACKLOG_FAILURES" ]; then
  emit_keyword backlog-error ''
  exit 0
fi
if [ -z "$SCORED" ]; then
  emit_keyword no-candidates ''
  exit 0
fi
if ! fm_jev_key_configured; then
  emit_keyword off ''
  exit 0
fi

# The bounded offer: best-scored first, topped up by recency, sanitized ids and
# titles only. offered is a JSON array of {id, state, path, title}.
offered='[]'
while IFS=$(printf '\t') read -r _score _order id state path title; do
  [ -n "$id" ] || continue
  clean_id=$(fm_jev_compact_state "$id") || continue
  [ "$clean_id" = "$id" ] || continue
  title=$(fm_jev_compact_state "$title") || title=''
  title=${title:0:$TITLE_MAX}
  offered=$(jq -c --arg id "$id" --arg state "$state" --arg path "$path" --arg title "$title" \
    '. + [{id: $id, state: $state, path: $path, title: $title}]' <<<"$offered") || continue
  [ "$(jq 'length' <<<"$offered")" -lt "$CANDIDATE_MAX" ] || break
done <<EOF
$SCORED
EOF

state=$(fm_jev_compact_state "$(printf "Captain reference: %s\nCandidates are this Firstmate home's backlog items and task records, offered by id and title only." "$REFERENCE")") || {
  emit_keyword error ''
  exit 0
}
none_choice='none?'
criteria=$(jq -c --arg none "$none_choice" '
  (map({key: .id, value: ((if .title == "" then .id else .title end) + " (backlog: " + .state + ")")}) | from_entries)
  + {($none): "No candidate is the record the captain means."}
' <<<"$offered") || { emit_keyword error ''; exit 0; }
questions=$(jq -nc --argjson c "$criteria" '{
  match: {
    type: "choice",
    instructions: "Pick the backlog item or task record the captain reference most likely means. Judge by id and title only. Pick the no-candidate option when no candidate fits.",
    criteria: $c
  }
}') || { emit_keyword error ''; exit 0; }

decide_code=0
mkdir -p "$STATE_DIR" 2>/dev/null || true
response=
if response_file=$(mktemp "$STATE_DIR/.jev-intake-match-response.XXXXXX" 2>/dev/null); then
  fm_jev_decide "$state" "$questions" > "$response_file" || decide_code=$?
  response=$(cat "$response_file" 2>/dev/null)
  rm -f "$response_file"
else
  decide_code=2
fi

choice=
confidence=
ranked='[]'
ranking=keyword
fallback=error
if [ "$decide_code" -eq 0 ] && [ -n "$response" ]; then
  choice=$(jq -r '.answers.match.choice // empty' <<<"$response" 2>/dev/null)
  confidence=$(jq -r '.answers.match.confidence | select(type == "number") // empty' <<<"$response" 2>/dev/null)
  if [ -z "$choice" ]; then
    fallback=error
  elif [ "$choice" = "$none_choice" ]; then
    fallback=no-match
  elif ! jq -e --arg id "$choice" 'any(.[]; .id == $id)' <<<"$offered" >/dev/null 2>&1; then
    fallback=error
  elif [ -z "$confidence" ] || ! fm_jev_choice_confidence_ok "$confidence"; then
    fallback=low-confidence
  else
    ranking=jev
    fallback=none
    probs=$(jq -c '.answers.match.probabilities // empty' <<<"$response" 2>/dev/null)
    if [ -n "$probs" ] && fm_jev_probabilities_sum_ok "$probs" \
      && jq -en --argjson p "$probs" --argjson offered "$offered" --arg none "$none_choice" \
        'all($p | keys[]; . as $key | ($key == $none or any($offered[]; .id == $key)))' \
        >/dev/null 2>&1; then
      if jq -en --argjson p "$probs" --argjson offered "$offered" \
        'any($offered[]; ($p[.id] // 0) > 0)' >/dev/null 2>&1; then
        ranked=$(jq -c --argjson p "$probs" '
          map(. + {confidence: ($p[.id] // 0)})
          | map(select(.confidence > 0))
          | sort_by(-.confidence)
        ' <<<"$offered")
      else
        ranking=keyword
        fallback=no-candidate-probability
      fi
    else
      ranked=$(jq -c --arg choice "$choice" --arg conf "$confidence" \
        'map(select(.id == $choice) | . + {confidence: ($conf | tonumber)})' <<<"$offered")
    fi
  fi
fi

payload=$(jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)" \
  --argjson reference_chars "${#REFERENCE}" \
  --arg reference_sha256 "$(printf '%s' "$REFERENCE" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -d ' ' -f 1)" \
  --arg choice "$choice" \
  --arg confidence "$confidence" \
  --arg ranking "$ranking" \
  --arg fallback "$fallback" \
  --arg route "${FM_JEV_LAST_ROUTE:-}" \
  --arg http "${FM_JEV_LAST_HTTP:-}" \
  --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
  --argjson offered "$(jq -c '[.[].id]' <<<"$offered")" \
  --argjson ranked "$(jq -c '[.[:5][].id]' <<<"$ranked")" \
  --argjson decide_code "$decide_code" \
  '{
    purpose: "intake-match",
    advisory: true,
    reference_chars: $reference_chars,
    reference_sha256: $reference_sha256,
    offered_ids: $offered,
    choice: (if $choice == "" then null else $choice end),
    confidence: (try ($confidence | tonumber) catch null),
    ranked_ids: $ranked,
    ranking: $ranking,
    fallback: $fallback,
    route: $route,
    http: $http,
    latency_ms: (try ($latency | tonumber) catch null),
    decide_code: $decide_code,
    ts: $ts
  }' 2>/dev/null) && fm_jev_log_call "$payload" "$LOG_PATH" || true

if [ "$ranking" != jev ]; then
  emit_keyword "$fallback" "$confidence"
  exit 0
fi
emit_header jev none "$confidence"
printf '  candidates:\n'
jq -r --argjson max "$SHOW_MAX" '
  .[:$max] | to_entries[]
  | "    \(.key + 1). \(.value.id) confidence=\(.value.confidence) state=\(.value.state) record=\(.value.path) title=\(.value.title)"
' <<<"$ranked"
emit_related "$(jq -r --argjson max "$SHOW_MAX" '.[:$max][] | "\(.id)\t\(.path)"' <<<"$ranked")"
exit 0
