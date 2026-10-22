#!/usr/bin/env bash
# fm-reports-page.sh - build the offline reports page for this home.
#
# Scout reports pile up as data/<id>/report.md and are read one path at a time.
# This script renders all of them into ONE self-contained page so a report can
# be found by searching and reached by a stable link. The page is a plain file:
# it carries no network request, loads no external asset, and needs no server,
# timer, or unit. Rebuilding it is the whole mechanism.
#
# A report describes work that some captain decision allowed, and that decision
# is recorded in the task it gated rather than in the report. So the page also
# carries this home's recorded decisions, read by bin/fm-reports-decisions.sh:
# beside the report of the same task, and - where a decision gated no report of
# this home at all - as its own entry in the same list, with its own anchor.
# Without that, a decision the captain gave weeks ago stays unfindable, and the
# work a report describes cannot be traced back to the word that permitted it.
#
# Usage:
#   fm-reports-page.sh build
#   fm-reports-page.sh path
#   fm-reports-page.sh link <id>
#
# build      Read every data/<id>/report.md of this home, render each to HTML
#            and this home's recorded decisions through bin/fm-reports-render.jq
#            (that file owns the rendered markdown subset and how a decision
#            joins a report), embed the result in the shipped template
#            (.agents/skills/reports-page/assets/page-template.html), and
#            publish it atomically at the stable page path. Output is either
#               page: <path>
#               reports: <n>
#               decisions: <n>
#               entries: <n>
#            or, when the rebuilt page would be byte-identical apart from its
#            own build stamp, the same with `unchanged: <path>` as its first
#            line. Every configured or default data source that should have
#            contributed but could not is named on its own `source:` line, and
#            the page names it too. A missing .tasks.toml is not such a source
#            because its absence selects the default paths. A home with no
#            report and no decision publishes the page's
#            empty state rather than refusing, so the path a skill hands out
#            always resolves.
# path       Print the stable page path for this home.
# link <id>  Print the page link for one entry, as file://<path>#<id>, after
#            proving the PUBLISHED page actually carries that anchor. A link is
#            never assembled by hand: an anchor to a report that was deleted, or
#            to one written since the last build, looks live and silently shows
#            a different entry. Proving it against the published payload is also
#            what makes a decision's own anchor available at all, since a
#            decision that gated no report has no report path to check.
#
# WHY ONLY ON CHANGE. A rebuild that rewrote the page every run would move its
# modification time on every run, so neither a reader nor a later check could
# tell a new report from a repeated build. The published page is therefore
# compared against the freshly built one with each side's own build stamp
# masked, and an unchanged page is left untouched.
#
# NOTHING FROM A REPORT CAN ESCAPE ITS SLOT. Report text reaches the page twice,
# and both ways are closed: as rendered HTML, where fm-reports-render.jq escapes
# every line before it builds any markup, and as the embedded JSON payload,
# where `<` plus the two unicode line separators are escaped so no report can
# end the script element or break the parse. The build then reads its own
# payload back out of the finished page and refuses a page the browser could
# not parse.
#
# The data directory is read-only to this script. Inside the home it writes
# exactly one file, the page, and its own staging file beside it; its rows and
# payload are staged under TMPDIR and removed on every path out.
#
# FM_REPORTS_PAGE_TEMPLATE overrides the shipped template path, and
# FM_REPORTS_PAGE_DECISIONS=off builds with no decisions at all (tests only).
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TEMPLATE="${FM_REPORTS_PAGE_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/reports-page/assets/page-template.html}"
RENDERER="$SCRIPT_DIR/fm-reports-render.jq"
COLLECTOR="$SCRIPT_DIR/fm-reports-decisions.sh"
DATA_SLOT='__FM_REPORTS_DATA__'
BUILT_LINE='const BUILT = "__FM_REPORTS_BUILT__";'
BUILT_LINE_RE='^const BUILT = ".*";$'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-reports-page: %s\n' "$*" >&2
  exit 1
}

require_home() {
  [ -n "${FM_HOME:-}" ] || fail "FM_HOME is not set"
  [ -d "$FM_HOME" ] || fail "FM_HOME is not a directory: $FM_HOME"
}

page_path() { printf '%s/state/reports.html\n' "$FM_HOME"; }

# Local modification time in seconds, portable across GNU and BSD stat.
mtime_of() {  # <path>
  stat -c '%Y' -- "$1" 2>/dev/null || stat -f '%m' -- "$1" 2>/dev/null
}

# One report -> one compact JSON object on stdout. jq reads the report as raw
# text, so nothing in it is ever interpreted as JSON or as a shell word.
report_json() {  # <id> <path> <ts>
  jq -cn --arg id "$1" \
         --arg file "data/$1/report.md" \
         --arg updated "$(date -d "@$3" '+%d.%m.%Y %H:%M' 2>/dev/null \
                          || date -r "$3" '+%d.%m.%Y %H:%M')" \
         --argjson ts "$3" \
         --rawfile md "$2" \
         '{id: $id, file: $file, updated: $updated, ts: $ts, md: $md}'
}

# The page's own build stamp is the one line that legitimately differs between
# two builds of the same reports, so it is masked on both sides of the
# comparison. Only the FIRST match is masked: a report may quote that very line
# in its own text, and that occurrence is content, not the stamp.
mask_built_line() {  # reads a page on stdin
  awk -v re="$BUILT_LINE_RE" '
    !done && $0 ~ re { print "const BUILT = \"\";"; done = 1; next }
    { print }
  '
}

# The build's own counts, plus one line per source of decisions that did not
# read cleanly. Defined beside the build because it reads its locals.
report_counts() {
  printf 'reports: %s\n' "$count"
  printf 'decisions: %s\n' "$dcount"
  printf 'entries: %s\n' "$((count + ocount))"
  [ -z "$gaps" ] || printf '%s\n' "$gaps"
}

command_build() {
  local page tmp dir id ts payload rows decisions count dcount ocount built gaps
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  require_home
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$RENDERER" ] && [ ! -L "$RENDERER" ] || fail "renderer is missing: $RENDERER"
  [ -x "$COLLECTOR" ] && [ ! -L "$COLLECTOR" ] || fail "decision reader is missing: $COLLECTOR"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "page template is missing: $TEMPLATE"
  [ "$(grep -cxF "$DATA_SLOT" "$TEMPLATE")" -eq 1 ] \
    || fail "page template does not carry exactly one data slot: $TEMPLATE"
  [ "$(grep -cxF "$BUILT_LINE" "$TEMPLATE")" -eq 1 ] \
    || fail "page template does not carry exactly one build stamp: $TEMPLATE"

  # The decisions are collected before anything is rendered, because a source
  # that could not be read has to reach the page as a named gap rather than as
  # silence. A collector that fails outright is itself such a gap: the page is
  # still built, and says so.
  decisions=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-reports-decisions.XXXXXX") \
    || fail "cannot stage the decisions"
  if [ "${FM_REPORTS_PAGE_DECISIONS:-}" = off ]; then
    printf '{"sources":[],"tasks":[]}\n' > "$decisions" \
      || { rm -f -- "$decisions"; fail "cannot stage the decisions"; }
  elif ! "$COLLECTOR" collect > "$decisions" 2>/dev/null; then
    jq -cn '{sources: [{name: "decisions", state: "unreadable",
                        note: "the decisions of this home could not be read"}],
             tasks: []}' > "$decisions" \
      || { rm -f -- "$decisions"; fail "cannot record the unread decisions"; }
  fi

  rows=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-reports-rows.XXXXXX") \
    || { rm -f -- "$decisions"; fail "cannot stage the report rows"; }
  count=0
  for dir in "$FM_HOME"/data/*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    id=${dir%/}
    id=${id##*/}
    [ -f "$dir/report.md" ] && [ ! -L "$dir/report.md" ] || continue
    ts=$(mtime_of "$dir/report.md") \
      || { rm -f -- "$rows" "$decisions"; fail "cannot read the time of $dir/report.md"; }
    [ -n "$ts" ] \
      || { rm -f -- "$rows" "$decisions"; fail "cannot read the time of $dir/report.md"; }
    if ! report_json "$id" "$dir/report.md" "$ts" >> "$rows"; then
      rm -f -- "$rows" "$decisions"
      fail "cannot read report $id"
    fi
    count=$((count + 1))
  done

  # One render pass over all reports and all decisions: the renderer takes the
  # report rows as its input and the collected decisions as $dec, joins each
  # decision to the report it belongs to, and sorts the whole list newest first.
  #
  # The payload stays a FILE and is never held in a shell variable. `<` never
  # appears in JSON syntax outside strings, and U+2028/U+2029 are literal line
  # terminators to a browser's parser but ordinary characters to JSON, so
  # escaping all three keeps the payload valid JSON that no report can break
  # out of - but bash substitutes a pattern over a megabyte of reports in
  # minutes, while the same three substitutions cost milliseconds in the
  # stream. The escapes run on raw bytes so neither line separator has to sit
  # in this source as an invisible character.
  payload=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-reports-payload.XXXXXX") \
    || { rm -f -- "$rows" "$decisions"; fail "cannot stage the report payload"; }
  # pipefail is set for this one pipeline only: without it a failing renderer
  # would be hidden behind a perl that happily copied nothing.
  if ! ( set -o pipefail
         jq -cs --slurpfile dec "$decisions" -f "$RENDERER" "$rows" \
           | perl -pe 's/</\\u003c/g;
                       s/\xe2\x80\xa8/\\u2028/g;
                       s/\xe2\x80\xa9/\\u2029/g;' ) > "$payload"
  then
    rm -f -- "$rows" "$payload" "$decisions"
    fail "cannot render the reports"
  fi
  rm -f -- "$rows"
  [ -s "$payload" ] || { rm -f -- "$payload" "$decisions"; fail "the renderer produced nothing"; }

  # What the counts mean: a decision is one recorded item, and an entry is one
  # row of the page's list - every report, plus every decision group that gated
  # no report of this home.
  dcount=$(jq '[.tasks[].items | length] | add // 0' "$decisions") \
    || { rm -f -- "$payload" "$decisions"; fail "cannot count the decisions"; }
  ocount=$(jq '[.tasks[] | select(.target == null)] | length' "$decisions") \
    || { rm -f -- "$payload" "$decisions"; fail "cannot count the decisions"; }
  # Named now, while the collected decisions are still staged, and printed with
  # the counts below.
  gaps=$(jq -r '.sources[] | select(.state != "ok")
                | "source: \(.name) \(.state) - \(.note)"' "$decisions") \
    || { rm -f -- "$payload" "$decisions"; fail "cannot read the decision sources"; }

  page=$(page_path)
  (umask 077; mkdir -p "${page%/*}") \
    || { rm -f -- "$payload" "$decisions"; fail "cannot create ${page%/*}"; }
  built=$(date '+%d.%m.%Y %H:%M')
  tmp=$(umask 077; mktemp "${page%/*}/.reports.XXXXXX") \
    || { rm -f -- "$payload" "$decisions"; fail "cannot stage the page"; }
  # The data slot line is replaced by the payload file read whole, so no report
  # text is ever itself scanned for a slot and no report can become a
  # substitution target of the pass that injects it.
  if ! REPORTS_BUILT="$built" REPORTS_DATA_FILE="$payload" perl -pe '
        s/^\Q'"$BUILT_LINE"'\E$/const BUILT = "$ENV{REPORTS_BUILT}";/;
        if (/^\Q'"$DATA_SLOT"'\E$/) {
          open(my $fh, "<", $ENV{REPORTS_DATA_FILE}) or die "payload: $!";
          local $/;
          $_ = <$fh>;
          close($fh);
        }
      ' "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp" "$payload" "$decisions"
    fail "cannot inject the reports data"
  fi
  rm -f -- "$payload" "$decisions"
  if grep -qxF "$DATA_SLOT" "$tmp" || grep -qxF "$BUILT_LINE" "$tmp"; then
    rm -f -- "$tmp"
    fail "a page slot survived injection"
  fi
  # Read the payload back out of the finished page, so a page the browser could
  # not parse fails here instead of in the captain's hands. The extract is piped
  # rather than captured: a shell variable would hold every report again.
  if ! sed -n '/<script id="reports-data" type="application\/json">/,/<\/script>/p' "$tmp" \
       | sed '1d;$d' \
       | jq -e --argjson n "$((count + ocount))" '.entries | length == $n' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built page does not carry a readable payload of $((count + ocount)) entries"
  fi

  if [ -f "$page" ] && [ ! -L "$page" ] \
     && cmp -s <(mask_built_line < "$tmp") <(mask_built_line < "$page"); then
    rm -f -- "$tmp"
    printf 'unchanged: %s\n' "$page"
    report_counts
    return 0
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$page"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the page"
  fi
  printf 'page: %s\n' "$page"
  report_counts
}

command_path() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  require_home
  page_path
}

command_link() {
  local id=${1-} page
  [ "$#" -eq 1 ] && [ -n "$id" ] || { usage >&2; exit 2; }
  require_home
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  page=$(page_path)
  [ -f "$page" ] && [ ! -L "$page" ] || fail "the page is not built yet: $page"
  # The published payload is read the way the page's own script reads it, so the
  # proof is that THIS page resolves THIS anchor.
  if ! sed -n '/<script id="reports-data" type="application\/json">/,/<\/script>/p' "$page" \
       | sed '1d;$d' \
       | jq -e --arg id "$id" 'any(.entries[]; .id == $id)' >/dev/null 2>&1; then
    fail "the page carries no entry for $id; rebuild it if that is new"
  fi
  printf 'file://%s#%s\n' "$page" "$id"
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) shift; command_path "$@" ;;
  link) shift; command_link "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
