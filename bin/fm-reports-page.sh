#!/usr/bin/env bash
# fm-reports-page.sh - build the offline reports page for this home.
#
# Scout reports pile up as data/<id>/report.md and are read one path at a time.
# This script renders all of them into ONE self-contained page so a report can
# be found by searching and reached by a stable link. The page is a plain file:
# it carries no network request, loads no external asset, and needs no server,
# timer, or unit. Rebuilding it is the whole mechanism.
#
# Usage:
#   fm-reports-page.sh build
#   fm-reports-page.sh path
#   fm-reports-page.sh link <id>
#
# build      Read every data/<id>/report.md of this home, render each to HTML
#            through bin/fm-reports-render.jq (that file owns the rendered
#            markdown subset), embed the result in the shipped template
#            (.agents/skills/reports-page/assets/page-template.html), and
#            publish it atomically at the stable page path. Output is either
#               page: <path>
#               reports: <n>
#            or, when the rebuilt page would be byte-identical apart from its
#            own build stamp,
#               unchanged: <path>
#               reports: <n>
#            A home with no report publishes the page's empty state rather than
#            refusing, so the path a skill hands out always resolves.
# path       Print the stable page path for this home.
# link <id>  Print the page link for one report, as file://<path>#<id>, after
#            proving that report exists. A link is never assembled by hand: a
#            report whose directory is gone would otherwise be handed out as a
#            dead anchor that looks live.
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
# The data directory is read-only to this script. It writes exactly one file,
# the page, and its own staging file beside it.
#
# FM_REPORTS_PAGE_TEMPLATE overrides the shipped template path (tests only).
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TEMPLATE="${FM_REPORTS_PAGE_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/reports-page/assets/page-template.html}"
RENDERER="$SCRIPT_DIR/fm-reports-render.jq"
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

report_path() { printf '%s/data/%s/report.md\n' "$FM_HOME" "$1"; }

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

command_build() {
  local page tmp dir id ts payload rows count built extracted
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  require_home
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$RENDERER" ] && [ ! -L "$RENDERER" ] || fail "renderer is missing: $RENDERER"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "page template is missing: $TEMPLATE"
  [ "$(grep -cxF "$DATA_SLOT" "$TEMPLATE")" -eq 1 ] \
    || fail "page template does not carry exactly one data slot: $TEMPLATE"
  [ "$(grep -cxF "$BUILT_LINE" "$TEMPLATE")" -eq 1 ] \
    || fail "page template does not carry exactly one build stamp: $TEMPLATE"

  rows=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-reports-rows.XXXXXX") \
    || fail "cannot stage the report rows"
  count=0
  for dir in "$FM_HOME"/data/*/; do
    [ -d "$dir" ] || continue
    id=${dir%/}
    id=${id##*/}
    [ -f "$dir/report.md" ] && [ ! -L "$dir/report.md" ] || continue
    ts=$(mtime_of "$dir/report.md") || { rm -f -- "$rows"; fail "cannot read the time of $dir/report.md"; }
    [ -n "$ts" ] || { rm -f -- "$rows"; fail "cannot read the time of $dir/report.md"; }
    if ! report_json "$id" "$dir/report.md" "$ts" >> "$rows"; then
      rm -f -- "$rows"
      fail "cannot read report $id"
    fi
    count=$((count + 1))
  done

  # One render pass over all reports: the renderer is a map over the array and
  # sorts it newest first.
  payload=$(jq -cs -f "$RENDERER" "$rows") || { rm -f -- "$rows"; fail "cannot render the reports"; }
  rm -f -- "$rows"
  # `<` never appears in JSON syntax outside strings, and U+2028/U+2029 are
  # literal line terminators to a browser's parser but ordinary characters to
  # JSON, so escaping all three keeps the payload valid JSON that no report can
  # break out of.
  payload=${payload//</\\u003c}
  # U+2028 and U+2029 written as their utf-8 bytes, so neither sits in this
  # source as an invisible line separator.
  payload=${payload//$'\xe2\x80\xa8'/\\u2028}
  payload=${payload//$'\xe2\x80\xa9'/\\u2029}

  page=$(page_path)
  (umask 077; mkdir -p "${page%/*}") || fail "cannot create ${page%/*}"
  built=$(date '+%d.%m.%Y %H:%M')
  tmp=$(umask 077; mktemp "${page%/*}/.reports.XXXXXX") || fail "cannot stage the page"
  # The build stamp is replaced BEFORE the data, so a report that contains the
  # literal stamp slot in its own text cannot become a substitution target.
  if ! REPORTS_BUILT="$built" REPORTS_DATA="$payload" perl -pe '
        s/^\Q'"$BUILT_LINE"'\E$/const BUILT = "$ENV{REPORTS_BUILT}";/;
        s/^\Q'"$DATA_SLOT"'\E$/$ENV{REPORTS_DATA}/;
      ' "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the reports data"
  fi
  if grep -qxF "$DATA_SLOT" "$tmp" || grep -qxF "$BUILT_LINE" "$tmp"; then
    rm -f -- "$tmp"
    fail "a page slot survived injection"
  fi
  # Read the payload back out of the finished page, so a page the browser could
  # not parse fails here instead of in the captain's hands.
  extracted=$(sed -n '/<script id="reports-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --argjson n "$count" 'length == $n' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built page does not carry a readable payload of $count reports"
  fi

  if [ -f "$page" ] && [ ! -L "$page" ] \
     && cmp -s <(mask_built_line < "$tmp") <(mask_built_line < "$page"); then
    rm -f -- "$tmp"
    printf 'unchanged: %s\n' "$page"
    printf 'reports: %s\n' "$count"
    return 0
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$page"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the page"
  fi
  printf 'page: %s\n' "$page"
  printf 'reports: %s\n' "$count"
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
  [ -f "$(report_path "$id")" ] || fail "no such report: $id"
  page=$(page_path)
  [ -f "$page" ] || fail "the page is not built yet: $page"
  printf 'file://%s#%s\n' "$page" "$id"
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) shift; command_path "$@" ;;
  link) shift; command_link "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
