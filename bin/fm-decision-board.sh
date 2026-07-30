#!/usr/bin/env bash
# fm-decision-board.sh - the captain's daily decision board, rendered from the
# canonical fleet snapshot.
#
# A thin renderer OVER bin/fm-fleet-snapshot.sh, in the same shape as
# fm-fleet-view.sh and fm-bearings-snapshot.sh: it never parses the backlog,
# task metadata, or status logs itself. It shells out to
# `fm-fleet-snapshot.sh --json`, selects the captain-owned open items from that
# stable contract, and renders them. Backlog and decision semantics stay owned
# by the snapshot; this script owns only the projection and the presentation.
#
# Two sources feed the board, both already normalized by the snapshot:
#   1. backlog records still open with hold_kind == "captain" - the durable
#      captain-gated queue maintained through bin/fm-decision-hold.sh.
#   2. tasks whose hints.open_decisions carries a needs-decision event - a
#      worker parked right now on an ask-user finding that the captain (or
#      firstmate's configured authority) must answer.
# An id present in both is ONE board entry carrying both facts, never two rows.
#
# Entries are split by whether the captain's answer is enough on its own:
#   ready  - nothing else is in the way; his answer releases the work.
#   gated  - captain-owned, but unfinished work must land first.
# A parked worker is always ready: it is stopped on this answer right now, so no
# other unfinished work can release it. Any remaining dependency still prints.
# Within each group the longest-waiting entry sorts first, then id, so the
# staleness that motivates the daily cadence is visible at the top.
#
# Output is captain-facing, so it follows AGENTS.md section 9: plain outcome
# language, no internal vocabulary. Entries are NUMBERED because the captain
# answers these surfaces in bulk by position ("1 yes, 2 yes, 3 sure"); the
# durable id trails each entry so firstmate can act on the answer.
#
# Titles and questions are relayed VERBATIM from the durable record, bounded but
# never paraphrased: a generator that reworded them would be inventing the very
# thing the captain is answering. Section 9 translation is therefore a duty of
# whoever WRITES a backlog entry, and this renderer only enforces the parts it
# can carry honestly - project names instead of paths, and plain group wording.
#
# Usage:
#   fm-decision-board.sh [--format markdown|html|json] [--snapshot <path>]
#                        [--limit <n>] [--title <text>]
#
#   --format markdown  (default) drop-in section for the morning packet
#   --format html      standalone page for an on-demand captain surface
#   --format json      the projected model (schema fm-decision-board.v1)
#   --snapshot <path>  read an existing fm-fleet-snapshot.v1 document instead of
#                      running a fresh snapshot; "-" reads standard input
#   --limit <n>        cap entries per group (default 25; 0 means no cap).
#                      Anything dropped is disclosed in omitted[] and in the
#                      rendered footer, so a bounded board never reads complete.
#   --title <text>     override the rendered heading
#
# Read-only: no locks, no mutation, no network. Exits 3 when the snapshot is
# missing its backlog source, so an empty board is never confused with a
# board that could not be built.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/fm-fleet-snapshot.sh"

SCHEMA=fm-decision-board.v1
FORMAT=markdown
SNAPSHOT_PATH=""
LIMIT=25
TITLE="Captain decision board"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-board: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --format) shift; FORMAT=${1:-} ;;
    --format=*) FORMAT=${1#--format=} ;;
    --snapshot) shift; SNAPSHOT_PATH=${1:-} ;;
    --snapshot=*) SNAPSHOT_PATH=${1#--snapshot=} ;;
    --limit) shift; LIMIT=${1:-} ;;
    --limit=*) LIMIT=${1#--limit=} ;;
    --title) shift; TITLE=${1:-} ;;
    --title=*) TITLE=${1#--title=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$FORMAT" in
  markdown|html|json) ;;
  *) fail "unknown --format '$FORMAT' (markdown, html, json)" ;;
esac
case "$LIMIT" in
  ''|*[!0-9]*) fail "--limit must be a non-negative integer" ;;
esac
[ -n "$TITLE" ] || fail "--title must not be empty"

command -v jq >/dev/null 2>&1 || fail "jq not found"

if [ -n "$SNAPSHOT_PATH" ]; then
  if [ "$SNAPSHOT_PATH" = - ]; then
    SNAP=$(cat)
  else
    [ -r "$SNAPSHOT_PATH" ] || fail "cannot read snapshot: $SNAPSHOT_PATH"
    SNAP=$(cat "$SNAPSHOT_PATH")
  fi
else
  SNAP=$("$FLEET" --json) || exit $?
fi

printf '%s' "$SNAP" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || fail "snapshot is not a JSON object"

NOW=${FM_DECISION_BOARD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

# --- projection -------------------------------------------------------------
#
# One jq program builds the whole model so every renderer below reads the same
# facts. Truncation bounds match the snapshot's own so a long backlog line
# cannot blow up a packet section.
MODEL=$(printf '%s' "$SNAP" | jq \
  --arg schema "$SCHEMA" \
  --arg now "$NOW" \
  --arg title "$TITLE" \
  --argjson limit "$LIMIT" '
  def trunc($n):
    if . == null then null
    else tostring | gsub("\\s+"; " ") | if length > $n then .[:$n] + "…" else . end
    end;

  # A registry entry may name a project by absolute path. The captain reads the
  # project, never the path (AGENTS.md section 9), so keep only the last segment.
  def project_name:
    if . == null then null
    else tostring | sub("/+$"; "") | split("/") | last
    end;

  def date_prefix:
    if type != "string" then null
    else try (([capture("^(?<d>\\d{4}-\\d{2}-\\d{2})").d] | first) // null) catch null
    end;

  def date_epoch:
    if . == null then null
    else
      . as $date
      | (try (strptime("%Y-%m-%d") | mktime) catch null)
      | if . == null or (strftime("%Y-%m-%d") != $date) then null else . end
    end;

  # Whole days between an ISO date prefix and now; null when either is unusable.
  def waiting_days($since; $now):
    ($since | date_prefix | date_epoch) as $s
    | ($now | date_prefix | date_epoch) as $n
    | if $s == null or $n == null then null
      else
        (($n - $s) / 86400 | floor)
        | if . < 0 then null else . end
      end;

  def waiting_error($id; $since):
    if $since == null or ($since | date_prefix | date_epoch) != null then null
    else "Could not read waiting date for \($id): \($since | trunc(120))."
    end;

  . as $snap
  | ($snap.backlog.present == true) as $backlog_present

  # Captain-owned backlog entries that are still open.
  | ([ $snap.backlog.records[]?
       | select(.structured == true and .state != "done" and .hold_kind == "captain")
       | {
           id: (.id // "unknown"),
           title: (.title | trunc(200)),
           question: (.hold_reason | trunc(320)),
           repo: (.repo | project_name | trunc(120)),
           since: (.since // null),
           blocked_by: ((.unresolved_blocker_ids // []) | map(trunc(120))),
           sources: ["queue"]
         } ]) as $queue

  # Workers parked on an unanswered decision right now.
  | ([ $snap.tasks[]?
       | select((.hints.open_decisions // []) | any(.verb == "needs-decision"))
       | {
           id: (.id // "unknown"),
           title: ((.backlog.title // .id) | trunc(200)),
           question: (((.hints.open_decisions // [])
                        | map(select(.verb == "needs-decision"))
                        | map(.summary // "") | map(select(. != ""))
                        | join(" · ")) | trunc(320)),
           repo: ((.backlog.repo // .project) | project_name | trunc(120)),
           since: (.backlog.since // null),
           blocked_by: [],
           sources: ["parked"]
         } ]) as $parked

  # One entry per id. A queue entry keeps its durable wording and gains the
  # parked fact; a parked-only worker becomes its own entry.
  | ([ $queue[] | .id ]) as $queue_ids
  | ($queue
     + [ $parked[] | select(.id as $i | $queue_ids | index($i) | not) ]) as $merged
  | ([ $parked[] | .id ]) as $parked_ids
  | ([ $merged[]
       | . as $entry
       | .parked = ($parked_ids | index($entry.id) != null)
       | .parked_note = (if ($parked_ids | index($entry.id)) == null then null
                         else ([ $parked[] | select(.id == $entry.id) | .question ] | first)
                         end)
       | .sources = (if ($parked_ids | index($entry.id)) == null then .sources
                     else (.sources + ["parked"] | unique) end)
       | .waiting_days = waiting_days(.since; $now)
       | .waiting_error = waiting_error(.id; .since)
       | .ready = (.parked or ((.blocked_by | length) == 0))
     ]) as $entries

  | (def order: sort_by([(0 - (.waiting_days // -1)), .id]);
     [ $entries[] | select(.ready) ] | order) as $ready_all
  | (def order: sort_by([(0 - (.waiting_days // -1)), .id]);
     [ $entries[] | select(.ready | not) ] | order) as $gated_all

  | (if $limit == 0 then $ready_all else $ready_all[:$limit] end) as $ready
  | (if $limit == 0 then $gated_all else $gated_all[:$limit] end) as $gated

  | {
      schema: $schema,
      generated: $now,
      title: $title,
      home: ($snap.fm_home // null),
      source_present: $backlog_present,
      counts: {
        total: ($entries | length),
        ready: ($ready_all | length),
        gated: ($gated_all | length),
        parked: ([ $entries[] | select(.parked) ] | length),
        shown: (($ready | length) + ($gated | length))
      },
      ready: $ready,
      gated: $gated,
      omitted: [
        if ($ready_all | length) > ($ready | length) then
          {surface: "ready", count: (($ready_all | length) - ($ready | length)),
           reveal: "--limit 0"}
        else empty end,
        if ($gated_all | length) > ($gated | length) then
          {surface: "gated", count: (($gated_all | length) - ($gated | length)),
           reveal: "--limit 0"}
        else empty end,
        if $backlog_present != true then
          {surface: "queue", count: 0, reveal: "no readable decision queue"}
        else empty end
      ]
    }
  ') || fail "could not project the fleet snapshot"

printf '%s' "$MODEL" | jq -e '.source_present == true' >/dev/null 2>&1 \
  || { echo "fm-decision-board: no readable decision queue in the fleet snapshot" >&2; exit 3; }

# --- renderers --------------------------------------------------------------

render_markdown() {
  printf '%s' "$MODEL" | jq -r '
    def dash($v): if $v == null or $v == "" then null else $v end;
    def waited($e):
      if $e.waiting_days == null then null
      elif $e.waiting_days == 0 then "raised today"
      elif $e.waiting_days == 1 then "waiting 1 day"
      else "waiting \($e.waiting_days) days" end;
    def facts($e):
      [waited($e), dash($e.repo), (if $e.parked then "work is parked on it" else null end)]
      | map(select(. != null)) | join(" · ");
    def entry($e; $n):
      "\($n). **\($e.title)**"
      + (if dash($e.question) == null then "" else "\n   \($e.question)" end)
      + (if $e.parked and dash($e.parked_note) != null and $e.parked_note != $e.question
         then "\n   Worker is stopped here: \($e.parked_note)" else "" end)
      + (if ($e.blocked_by | length) > 0
         then "\n   Waiting first on: \($e.blocked_by | join(", "))" else "" end)
      + "\n   _\(facts($e))_ · `\($e.id)`";
    def errors($entries):
      [ $entries[] | select(.waiting_error != null) | "_Error: \(.waiting_error)_" ];

    (.ready | length) as $ready_shown
    | ["## \(.title)", ""]
    + (if .counts.total == 0 then
         ["Nothing is waiting on you."]
       else
         ["\(.counts.total) open · \(.counts.ready) need only your answer"
          + (if .counts.gated > 0 then " · \(.counts.gated) waiting on other work first" else "" end)
          + (if .counts.parked > 0 then " · \(.counts.parked) with work stopped on them" else "" end)
          + ".", ""]
         + (if (.ready | length) > 0 then
              ["### Needs your answer (\(.counts.ready))", ""]
              + errors(.ready)
              + [ .ready | to_entries[] | entry(.value; .key + 1) ]
              + [""]
            else [] end)
         + (if (.gated | length) > 0 then
              ["### Waiting on other work first (\(.counts.gated))", ""]
              + errors(.gated)
              + [ .gated | to_entries[] | entry(.value; .key + $ready_shown + 1) ]
              + [""]
            else [] end)
       end)
    + [ .omitted[] | "_\(.count) more \(.surface) not shown - reveal with `\(.reveal)`._" ]
    | .[]
  '
}

render_html() {
  printf '%s' "$MODEL" | jq -r '
    def esc: if . == null then "" else tostring | @html end;
    def dash($v): if $v == null or $v == "" then null else $v end;
    def waited($e):
      if $e.waiting_days == null then null
      elif $e.waiting_days == 0 then "raised today"
      elif $e.waiting_days == 1 then "waiting 1 day"
      else "waiting \($e.waiting_days) days" end;
    def facts($e):
      [waited($e), dash($e.repo)] | map(select(. != null)) | map(esc) | join(" · ");
    def entry($e; $n):
      ["<li class=\"item\">",
       "<div class=\"head\"><span class=\"num\">\($n)</span><span class=\"ttl\">\($e.title | esc)</span>"
       + (if $e.parked then "<span class=\"flag\">work parked</span>" else "" end)
       + "</div>",
       (if dash($e.question) == null then "" else "<p class=\"q\">\($e.question | esc)</p>" end),
       (if $e.parked and dash($e.parked_note) != null and $e.parked_note != $e.question
        then "<p class=\"q stop\">Worker is stopped here: \($e.parked_note | esc)</p>" else "" end),
       (if ($e.blocked_by | length) > 0
        then "<p class=\"q wait\">Waiting first on: \($e.blocked_by | map(esc) | join(", "))</p>"
        else "" end),
       "<p class=\"meta\">\(facts($e))<span class=\"id\">\($e.id | esc)</span></p>",
      "</li>"]
      | map(select(. != "")) | join("\n");
    def errors($entries):
      [ $entries[] | select(.waiting_error != null)
        | "<p class=\"error\">\(.waiting_error | esc)</p>" ];

    (.ready | length) as $ready_shown
    | ["<!doctype html>",
     "<html lang=\"en\"><head><meta charset=\"utf-8\">",
     "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
     "<title>\(.title | esc)</title>",
     "<style>",
     ":root{--bg:#0e1013;--fg:#e6e6e6;--dim:#8a9199;--line:#22262c;--accent:#e0b341;--stop:#e06c5b}",
     "@media(prefers-color-scheme:light){:root{--bg:#fbfbfa;--fg:#1a1c1f;--dim:#666d75;--line:#e0e0dd;--accent:#9a6b00;--stop:#b23c28}}",
     "*{box-sizing:border-box}",
     "body{margin:0;padding:2.5rem 1.25rem 4rem;background:var(--bg);color:var(--fg);",
     "font:14px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace}",
     "main{max-width:62rem;margin:0 auto}",
     "h1{font-size:1.05rem;letter-spacing:.14em;text-transform:uppercase;margin:0 0 .35rem}",
     "h2{font-size:.8rem;letter-spacing:.14em;text-transform:uppercase;color:var(--accent);",
     "margin:2.5rem 0 .75rem;padding-bottom:.4rem;border-bottom:1px solid var(--line)}",
     ".sub{color:var(--dim);margin:0 0 .25rem}",
     "ol{list-style:none;margin:0;padding:0}",
     ".item{padding:.9rem 0;border-bottom:1px solid var(--line)}",
     ".head{display:flex;gap:.75rem;align-items:baseline}",
     ".num{color:var(--accent);min-width:2ch;text-align:right}",
     ".ttl{font-weight:600}",
     ".flag{margin-left:auto;color:var(--stop);font-size:.75rem;letter-spacing:.1em;text-transform:uppercase}",
     ".q{margin:.35rem 0 0 2.75rem;color:var(--fg)}",
     ".q.stop{color:var(--stop)}",
     ".q.wait{color:var(--dim)}",
     ".error{color:var(--stop);margin:.5rem 0}",
     ".meta{margin:.4rem 0 0 2.75rem;color:var(--dim);font-size:.8rem}",
     ".id{margin-left:.6rem;opacity:.55}",
     ".empty,.omitted{color:var(--dim)}",
     ".omitted{margin-top:2rem;font-size:.8rem}",
     "</style></head><body><main>",
     "<h1>\(.title | esc)</h1>",
     "<p class=\"sub\">\(.generated | esc)</p>"]
    + (if .counts.total == 0 then
         ["<p class=\"empty\">Nothing is waiting on you.</p>"]
       else
         ["<p class=\"sub\">\(.counts.total) open · \(.counts.ready) need only your answer"
          + (if .counts.gated > 0 then " · \(.counts.gated) waiting on other work first" else "" end)
          + ".</p>"]
         + (if (.ready | length) > 0 then
              ["<h2>Needs your answer (\(.counts.ready))</h2>"]
              + errors(.ready) + ["<ol>"]
              + [ .ready | to_entries[] | entry(.value; .key + 1) ] + ["</ol>"]
            else [] end)
         + (if (.gated | length) > 0 then
              ["<h2>Waiting on other work first (\(.counts.gated))</h2>"]
              + errors(.gated) + ["<ol>"]
              + [ .gated | to_entries[] | entry(.value; .key + $ready_shown + 1) ] + ["</ol>"]
            else [] end)
       end)
    + [ .omitted[] | "<p class=\"omitted\">\(.count) more \(.surface | esc) not shown - reveal with \(.reveal | esc).</p>" ]
    + ["</main></body></html>"]
    | .[]
  '
}

case "$FORMAT" in
  json) printf '%s' "$MODEL" | jq . ;;
  markdown) render_markdown ;;
  html) render_html ;;
esac
