#!/usr/bin/env bash
# fm-report-index.sh - privacy-safe catalog of scout reports for session discovery.
#
# Problem (data/firstmate-context-gap-audit/report.md F-RET1, improvement E2):
# scout reports live at data/<id>/report.md, are gitignored, and never enter the
# session-start digest. A new session has no way to know which reports exist or
# what each concludes without firstmate remembering to grep the whole data/
# tree. This script builds a small, privacy-safe catalog so the digest can show
# a bounded "these reports exist, each is about X" tail without injecting any
# report body into context.
#
# THIS FILE IS THE SINGLE SCHEMA OWNER for two gitignored files under data/:
#
#   data/report-index.md   one line per indexed report, pipe-separated:
#     <id> | <date> | <project> | <title> | <summary> | <path>
#   data/report-index.skipped   one line per report that was not indexed:
#     <id> | <reason>
#     reason is one of: missing, no-title, unreadable, oversized. It carries
#     only the id and a category, never report content.
#
# Field extraction is DETERMINISTIC and uses no LLM at runtime (the task forbids
# a second LLM for semantic routing; this never calls one):
#   id       the directory name under data/ (privacy-safe; it is a fleet task
#            id, never report prose)
#   date     the first YYYY-MM-DD found in the report's head (scout reports
#            state their date near the top), else the file mtime, else "unknown"
#   project  the project slug parsed from data/<id>/brief.md's "disposable git
#            worktree of <slug>" line (the brief survives teardown alongside the
#            report), else "-" when no brief or no match
#   title    the first H1 ("# ") line of the report, stripped of the marker;
#            a report with no H1 is skipped as "no-title" (a titleless scout
#            report is not safely catalogable)
#   summary  the first content line after the report's summary/TL;DR heading
#            (matched on tokens: 摘要, TL;DR, 结论, Summary, Abstract, 概述,
#            Overview), with list markers and markdown bold stripped, capped at
#            SUMMARY_CAP chars; "-" when no summary section or no content line
#            is found (a report without a TL;DR is still cataloged by title)
#   path     data/<id>/report.md (recorded explicitly per the task; also
#            derivable from id, so a truncated digest line still reaches it)
#
# Safety boundaries (task requirements):
#   - Only the fields above are stored. Report BODIES never enter the index, a
#     skipped diagnostic, a tracked file, or a log. Extraction reads only the
#     bounded head of each report; the rest of the file is never read.
#   - Oversized reports (over MAX_REPORT_BYTES) are skipped as "oversized" so a
#     pathological or binary file can never make extraction unbounded. The cap is
#     generous (1 MiB) and overridable for unusual homes.
#   - rebuild is idempotent: the same inputs reproduce the same bytes (modulo
#     mtime-derived dates, which are stable for unchanged files). Re-running it
#     is always safe and is the resync path for homes with pre-existing reports.
#   - A per-report extraction failure never aborts the rebuild; that report is
#     skipped with a diagnostic and the rest are indexed.
#
# Who calls this:
#   - bin/fm-teardown.sh rebuilds after a scout's report is finalized (a scout
#     report survives teardown, so it is present and stable at that point).
#   - An operator or firstmate runs `rebuild` once to resync a home with reports
#     that predate this script.
#   - bin/fm-session-start.sh does NOT rebuild; it reads the prebuilt index file
#     and prints a bounded tail in the fleet-state digest, so startup stays off
#     any unbounded scan.
#
# Usage:
#   fm-report-index.sh rebuild        scan data/*/report.md and rebuild the index
#                                     (default action when no subcommand is given)
#   fm-report-index.sh show [--tail N]  print the current index to stdout, one
#                                     capped line per entry (manual inspection)
#   fm-report-index.sh --help | -h    print this header's usage section
#
# Environment:
#   FM_HOME (or FM_ROOT_OVERRIDE) selects the home whose data/ is indexed.
#   FM_REPORT_INDEX_TAIL bounds the show tail (default 8).
#   FM_REPORT_INDEX_MAX_BYTES overrides the oversized-report cap (default 1048576).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

INDEX_FILE="$DATA/report-index.md"
SKIPPED_FILE="$DATA/report-index.skipped"

# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

# Extraction bounds. Heads are bounded so a huge report never reads past the
# first lines that carry its title, date, and summary; the body is irrelevant
# to a catalog entry.
DATE_HEAD_LINES=40
TITLE_HEAD_LINES=40
SUMMARY_HEAD_LINES=80
TITLE_CAP=120
SUMMARY_CAP=140
MAX_REPORT_BYTES=${FM_REPORT_INDEX_MAX_BYTES:-1048576}

usage() {
  sed -n '/^# Usage:/,/^# Environment:/p' "$0" \
    | sed 's/^# \{0,1\}//'
}

# Field capping reuses bin/fm-line-cap-lib.sh's fm_cap_line_var so the
# per-line cut and its " [truncated]" marker have a single owner across both
# this index file and the session-start digest tail. The max is field-specific
# (TITLE_CAP, SUMMARY_CAP) to bound the durable index entry.

# report_date <path>: first YYYY-MM-DD in the head, else mtime, else unknown.
report_date() {
  local report=$1 date
  date=$(head -n "$DATE_HEAD_LINES" "$report" 2>/dev/null \
    | grep -m1 -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
  if [ -n "$date" ]; then
    printf '%s\n' "$date"
    return 0
  fi
  date=$(date -r "$report" '+%Y-%m-%d' 2>/dev/null || true)
  if [ -z "$date" ]; then
    # GNU coreutils date lacks -r's file form on some builds; stat is the
    # portable fallback. Either way, never fail the entry over a date.
    date=$(stat -f '%Sm' -t '%Y-%m-%d' "$report" 2>/dev/null \
      || stat -c '%y' "$report" 2>/dev/null | cut -c1-10 || true)
  fi
  printf '%s\n' "${date:-unknown}"
}

# report_project <id>: project slug from brief.md's worktree line, else "-".
report_project() {
  local id=$1 brief project
  brief="$DATA/$id/brief.md"
  [ -f "$brief" ] || { printf '%s\n' -; return 0; }
  project=$(grep -m1 -oE 'disposable git worktree of [^,[:space:]]+' "$brief" 2>/dev/null || true)
  project=${project#disposable git worktree of }
  printf '%s\n' "${project:-"-"}"
}

# report_title <path>: first H1 line stripped of "# ", empty when none found.
report_title() {
  local report=$1 title
  title=$(head -n "$TITLE_HEAD_LINES" "$report" 2>/dev/null \
    | awk '/^# /{sub(/^# /,"");print;exit}' || true)
  printf '%s\n' "$title"
}

# report_summary <path>: first content line after the summary/TL;DR heading,
# else the first content line after the H1, else empty.
report_summary() {
  local report=$1
  head -n "$SUMMARY_HEAD_LINES" "$report" 2>/dev/null \
    | awk '
      function is_summary_heading(line) {
        return (line ~ /摘要/ || line ~ /TL;DR/ || line ~ /TLDR/ || line ~ /结论/ || \
                line ~ /概述/ || tolower(line) ~ /summary/ || tolower(line) ~ /abstract/ || \
                tolower(line) ~ /overview/)
      }
      function is_content(line) {
        if (line ~ /^[[:space:]]*$/) return 0
        if (line ~ /^---+$/) return 0
        if (line ~ /^#+/) return 0
        return 1
      }
      function clean(line) {
        sub(/^[[:space:]]*[-*][[:space:]]+/, "", line)
        sub(/^[[:space:]]*[0-9]+\.[[:space:]]+/, "", line)
        sub(/^[[:space:]]*>[[:space:]]?/, "", line)
        gsub(/\*\*/, "", line)
        sub(/[[:space:]]+$/, "", line)
        return line
      }
      # Buffer the first content line after the H1 as a fallback, but do NOT
      # emit it yet: a TL;DR heading further down must win over an opening
      # metadata bullet. Only at END, if no summary-section line was emitted,
      # does the fallback print.
      BEGIN { seen_h1=0; in_summary=0; emitted=0; first_after_h1="" }
      /^# / { seen_h1=1; next }
      /^## / {
        if (is_summary_heading($0)) { in_summary=1; next }
        if (in_summary) exit
        next
      }
      in_summary && is_content($0) { print clean($0); emitted=1; exit }
      seen_h1 && !in_summary && first_after_h1=="" && is_content($0) { first_after_h1=clean($0) }
      END { if (emitted==0 && first_after_h1!="") print first_after_h1 }
    ' 2>/dev/null \
    | awk 'NF{print;exit}'
}

# index_entry <id> <report-path>: on success set INDEX_ENTRY_LINE to the
# pipe-separated catalog line and return 0; on a skip set SKIP_REASON to the
# diagnostic category and return 1. It assigns rather than prints so the caller
# gets the skip reason back too (a $(...) subshell would swallow the side
# effect and leave every skip defaulting to the same reason). Mirrors
# fm_cap_line_var's assign-don't-print shape. Never stores report body; only
# the capped catalog fields.
index_entry() {
  local id=$1 report=$2 size title date project summary path
  SKIP_REASON=
  INDEX_ENTRY_LINE=
  [ -f "$report" ] || { SKIP_REASON=missing; return 1; }
  # stat reports size without opening the file, so an unreadable report's
  # permission error never leaks here; the head gate below owns readability.
  size=$(stat -f%z "$report" 2>/dev/null || stat -c%s "$report" 2>/dev/null || true)
  if [ -n "$size" ] && [ "$size" -gt "$MAX_REPORT_BYTES" ]; then
    SKIP_REASON=oversized
    return 1
  fi
  if ! head -n "$TITLE_HEAD_LINES" "$report" >/dev/null 2>&1; then
    SKIP_REASON=unreadable
    return 1
  fi
  title=$(report_title "$report")
  if [ -z "$title" ]; then
    SKIP_REASON=no-title
    return 1
  fi
  date=$(report_date "$report")
  project=$(report_project "$id")
  summary=$(report_summary "$report")
  [ -n "$summary" ] || summary='-'
  path="data/$id/report.md"
  fm_cap_line_var "$title" "$TITLE_CAP"; title=$FM_LINE_CAP_LINE
  fm_cap_line_var "$summary" "$SUMMARY_CAP"; summary=$FM_LINE_CAP_LINE
  INDEX_ENTRY_LINE="$id | $date | $project | $title | $summary | $path"
  return 0
}

# rebuild: scan data/*/report.md, write the index and skipped files atomically.
rebuild() {
  local report tmp_index tmp_skipped id line entry_count=0 skipped_count=0
  [ -d "$DATA" ] || { echo "error: data directory not found: $DATA" >&2; return 1; }
  tmp_index=$(mktemp 2>/dev/null) || { echo "error: mktemp failed" >&2; return 1; }
  tmp_skipped=$(mktemp 2>/dev/null) || { rm -f "$tmp_index"; echo "error: mktemp failed" >&2; return 1; }
  {
    printf '# Scout report index. Schema owner: bin/fm-report-index.sh.\n'
    printf '# One line per report: id | date | project | title | summary | path.\n'
    printf '# Rebuild: bin/fm-report-index.sh rebuild. No report bodies here; read <path> for content.\n'
  } > "$tmp_index"
  : > "$tmp_skipped"
  # Deterministic lexical order so re-runs reproduce the same bytes.
  while IFS= read -r report; do
    [ -f "$report" ] || continue
    id=$(basename "$(dirname "$report")") || continue
    if index_entry "$id" "$report"; then
      printf '%s\n' "$INDEX_ENTRY_LINE" >> "$tmp_index"
      entry_count=$((entry_count + 1))
    else
      [ -n "${SKIP_REASON:-}" ] || SKIP_REASON=unreadable
      printf '%s | %s\n' "$id" "$SKIP_REASON" >> "$tmp_skipped"
      skipped_count=$((skipped_count + 1))
    fi
  done < <(find "$DATA" -mindepth 2 -maxdepth 2 -name report.md 2>/dev/null | LC_ALL=C sort)
  mv -f "$tmp_index" "$INDEX_FILE"
  if [ -s "$tmp_skipped" ]; then
    mv -f "$tmp_skipped" "$SKIPPED_FILE"
  else
    rm -f "$tmp_skipped" "$SKIPPED_FILE"
  fi
  printf 'indexed %d report(s), skipped %d; index: %s\n' \
    "$entry_count" "$skipped_count" "$INDEX_FILE"
}

# show [--tail N]: print the current index, one capped line per entry, newest
# entries last. Manual inspection path; the digest renders its own bounded tail.
show() {
  local tail_n=${FM_REPORT_INDEX_TAIL:-8}
  while [ $# -gt 0 ]; do
    case "$1" in
      --tail) shift; tail_n=${1:-$tail_n};;
      *) echo "unknown show argument: $1" >&2; return 2;;
    esac
    shift || true
  done
  case "$tail_n" in ''|*[!0-9]*) tail_n=8 ;; esac
  [ -f "$INDEX_FILE" ] || { echo "ABSENT: $INDEX_FILE (run bin/fm-report-index.sh rebuild)"; return 0; }
  grep -v '^#' "$INDEX_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n "$tail_n"
}

main() {
  local cmd=${1:-rebuild}
  [ $# -gt 0 ] && shift || true
  case "$cmd" in
    rebuild) rebuild "$@";;
    show) show "$@";;
    -h|--help) usage;;
    *) echo "unknown command: $cmd" >&2; usage >&2; return 2;;
  esac
}

main "$@"
