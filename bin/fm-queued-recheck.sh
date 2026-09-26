#!/usr/bin/env bash
# fm-queued-recheck.sh - still-true re-check scan over queued backlog records.
#
# A queued record whose declared deliverable already exists on disk, or whose
# named pull request has merged, must not sit silently in the ready queue.
# This command reports those records for a two-line still-true re-check. It
# never closes, holds, archives, or deletes a record, and it never removes a
# report file: cleanup that would drop undelivered follow-up content stays a
# human-owned act.
#
# Usage:
#   fm-queued-recheck.sh [--local | --with-pr] [--section]
#
# Default `--local` is a bounded local read: queued, unheld records whose
# `data/<id>/report.md` exists as a regular file, plus any previously confirmed
# merged-PR lines still matching those records (state/.queued-recheck-pr).
# It makes no forge call, so session-start and every wake drain can run it.
# `--with-pr` additionally reads named PR URLs from each record's structured
# `pr:` links (never title or body prose) and asks the forge whether each has
# merged. Merged-PR findings replace the cache; when a forge read fails, the
# previous cache line for that record and URL is kept.
# `--section` wraps the same findings in the agent-facing STILL-TRUE RE-CHECK
# heading; empty findings print nothing.
#
# Output without `--section`, one line per finding:
#   <id><TAB>report<TAB>data/<id>/report.md
#   <id><TAB>pr<TAB><canonical-pr-url>
#
# Silent (exit 0, no output) when nothing matches, when tasks-axi is missing,
# or when this process's state directory is not this home's state directory.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CACHE="$STATE/.queued-recheck-pr"

# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"
}

SECTION=0
WITH_PR=0
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --section) SECTION=1 ;;
    --with-pr) WITH_PR=1 ;;
    --local) WITH_PR=0 ;;
    *)
      printf 'fm-queued-recheck: unknown argument: %s\n' "$arg" >&2
      printf 'usage: fm-queued-recheck.sh [--local | --with-pr] [--section]\n' >&2
      exit 2
      ;;
  esac
done

show_field() {  # <show-output> <field>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

canonical_pr_urls() {  # <text>
  local token
  printf '%s\n' "$1" | tr ' \t<>"'"'"',' '\n' | while IFS= read -r token || [ -n "$token" ]; do
    token=${token#pr:}
    case "$token" in
      https://*|http://*) ;;
      *) continue ;;
    esac
    token=${token%/}
    fm_pr_url_parse "$token" || continue
    printf '%s\n' "$FM_PR_URL"
  done | LC_ALL=C sort -u
}

# Only structured `pr:` links name a PR. A URL cited in the title or body is
# prose (often the PR that caused the bug), not the work this record tracks.
# tasks-axi has no separate link field: `--pr` appends the URL to the end of
# the title, and `show` reports every title PR URL as a `pr:` link. So a link
# counts only when it sits in the title's trailing run of URLs, or when it is
# not in the title at all.
collect_pr_links() {  # <links-field> <title>
  local links title_all trailing="" rest word url
  links=$(canonical_pr_urls "$1")
  [ -n "$links" ] || return 0
  title_all=$(canonical_pr_urls "$2")
  rest=${2#\"}
  rest=${rest%\"}
  while :; do
    rest=${rest%"${rest##*[![:space:]]}"}
    word=${rest##*[[:space:]]}
    case "$word" in
      https://*|http://*) trailing="$trailing $word" ;;
      *) break ;;
    esac
    [ "$word" != "$rest" ] || break
    rest=${rest%"$word"}
  done
  trailing=$(canonical_pr_urls "$trailing")
  while IFS= read -r url; do
    if id_in_list "$trailing" "$url" || ! id_in_list "$title_all" "$url"; then
      printf '%s\n' "$url"
    fi
  done <<EOF
$links
EOF
}

# Exit 0 merged, 1 not merged, 2 the forge read failed.
pr_is_merged() {  # <url>
  fm_pr_url_parse "$1" || return 2
  case "$FM_PR_PROVIDER" in
    github)
      fm_pr_github_read_record "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER" || return 2
      ;;
    gitlab)
      fm_pr_gitlab_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || return 2
      ;;
    gerrit)
      fm_pr_gerrit_read_record "$FM_PR_HOST" "$FM_PR_NUMBER" || return 2
      ;;
    *)
      return 2
      ;;
  esac
  [ "${FM_PR_RECORD_MERGED:-}" = true ]
}

queued_unheld_ids() {  # <resolved-data-dir>
  fm_backlog_row_list "$1" --state queued --fields held 2>/dev/null | awk -F, '
    /^  [A-Za-z0-9._-]+,/ {
      id = $1
      sub(/^ +/, "", id)
      held = $NF
      gsub(/^[ \t]+|[ \t]+$/, "", held)
      if (held == "no") print id
    }
  '
}

write_cache() {  # <contents>
  local tmp
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp=$(mktemp "$STATE/.queued-recheck-pr.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! printf '%s' "$1" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$CACHE"
}

id_in_list() {  # <newline-list> <id>
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Same-home guard as bin/fm-captain-hold.sh diverged: a state override pointed
# at another home would mix one home's reports with another's backlog.
[ "$STATE" = "$FM_HOME/state" ] || exit 0
command -v tasks-axi >/dev/null 2>&1 || exit 0

DATA_ABS=$(fm_backlog_data_absolute "$DATA" 2>/dev/null) || exit 0
IDS=$(queued_unheld_ids "$DATA_ABS") || exit 0

PR_CACHE_OLD=
if [ -f "$CACHE" ] && [ ! -L "$CACHE" ] && [ -r "$CACHE" ]; then
  PR_CACHE_OLD=$(cat "$CACHE" 2>/dev/null || true)
fi

FINDINGS=
PR_CACHE_NEW=
while IFS= read -r id || [ -n "${id:-}" ]; do
  [ -n "$id" ] || continue
  report_rel="data/$id/report.md"
  report_abs="$DATA_ABS/$id/report.md"
  if [ -f "$report_abs" ] && [ ! -L "$report_abs" ]; then
    FINDINGS="${FINDINGS}${id}"$'\t'"report"$'\t'"${report_rel}"$'\n'
  fi
  if [ "$WITH_PR" -eq 1 ]; then
    show=$(fm_backlog_row_show "$DATA_ABS" "$id" --full) || continue
    urls=$(collect_pr_links "$(show_field "$show" links)" "$(show_field "$show" title)")
    while IFS= read -r url || [ -n "${url:-}" ]; do
      [ -n "$url" ] || continue
      merged=0
      pr_is_merged "$url" || merged=$?
      if [ "$merged" -eq 2 ]; then
        id_in_list "$PR_CACHE_OLD" "${id}"$'\t'"pr"$'\t'"${url}" || continue
      elif [ "$merged" -ne 0 ]; then
        continue
      fi
      FINDINGS="${FINDINGS}${id}"$'\t'"pr"$'\t'"${url}"$'\n'
      PR_CACHE_NEW="${PR_CACHE_NEW}${id}"$'\t'"pr"$'\t'"${url}"$'\n'
    done <<EOF
$urls
EOF
  fi
done <<EOF
$IDS
EOF

if [ "$WITH_PR" -eq 1 ]; then
  write_cache "$PR_CACHE_NEW" || true
else
  while IFS=$(printf '\t') read -r cid kind url || [ -n "${cid:-}" ]; do
    [ -n "$cid" ] || continue
    [ "$kind" = pr ] || continue
    [ -n "$url" ] || continue
    id_in_list "$IDS" "$cid" || continue
    FINDINGS="${FINDINGS}${cid}"$'\t'"pr"$'\t'"${url}"$'\n'
  done <<EOF
$PR_CACHE_OLD
EOF
fi

if [ -z "$FINDINGS" ]; then
  exit 0
fi

if [ "$SECTION" -eq 0 ]; then
  printf '%s' "$FINDINGS"
  exit 0
fi

item_bytes=220
global_bytes=2000
used=0
shown=0
omitted=0
output=
while IFS=$(printf '\t') read -r id kind detail || [ -n "${id:-}" ]; do
  [ -n "$id" ] || continue
  case "$kind" in
    report) line="$id declared report exists at $detail" ;;
    pr) line="$id named PR $detail has merged" ;;
    *) continue ;;
  esac
  fm_cap_line_var "$line" $((item_bytes - 1))
  line=$FM_LINE_CAP_LINE
  bytes=$(( ${#line} + 1 ))
  if [ $((used + bytes)) -gt "$global_bytes" ]; then
    omitted=$((omitted + 1))
    continue
  fi
  output="$output$line
"
  used=$((used + bytes))
  shown=$((shown + 1))
done <<EOF
$FINDINGS
EOF

[ "$shown" -gt 0 ] || [ "$omitted" -gt 0 ] || exit 0
printf 'STILL-TRUE RE-CHECK (queued records whose named work already landed - nothing was closed automatically):\n'
printf '%s' "$output"
if [ "$omitted" -gt 0 ]; then
  printf 'STILL-TRUE RE-CHECK: %d more omitted (byte cap)\n' "$omitted"
fi
printf 'STILL-TRUE RE-CHECK: confirm each record is still true in two lines, or close it through the ordinary landed-work path. Nothing here removes a record.\n'
