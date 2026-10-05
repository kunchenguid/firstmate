#!/usr/bin/env bash
# fm-backlog-pruner.sh - the weekly pruner for this home's backlog.
#
# Usage:
#   fm-backlog-pruner.sh run [--apply] [--days <n>] [--report-file <path>] [--fog <path>]
#   fm-backlog-pruner.sh check
#   fm-backlog-pruner.sh arm [--apply]
#   fm-backlog-pruner.sh disarm
#
# Two rules, both read from <data>/backlog.md and nothing else:
#   1. A queued item with no change for 7 days goes back to the fog file
#      (default <data>/backlog-fog.md) through one `tasks-axi mv`. Kept whole:
#      held captain calls, every in-flight item, items created or edited inside
#      the window, and any blocked-by set that would be split by the move. A
#      kept item pulls its blockers and dependents with it, exactly as the
#      05/10 fog classifier did, so `tasks-axi mv` never refuses a stranded link.
#   2. A queued or in-flight item whose note names pull or merge requests that
#      the forge reports ALL merged is listed for closing with those URLs. The
#      pruner never closes anything and never moves such an item; closing
#      in-flight work stays a firstmate decision. An item that names one merged
#      and one open request is not listed.
#
# `run` is a dry run: it writes only the report file (default
# <data>/backlog-prune-report.md) and prints a short summary. `run --apply`
# performs the move. "No change" is the newest of the item's `since` date and
# the last time its header or note text changed, which the pruner learns from
# <state>/backlog-pruner.seen (one `id<TAB>sha256<TAB>epoch` line per item; safe
# to delete, after which only `since` counts). Only `check` and `--apply`
# refresh that ledger, so a manual dry run leaves no trace outside its report.
#
# Periodic use rides the watcher's existing custom-check sweep, the same way
# bin/fm-contributions.sh does: `arm` writes state/backlog-pruner.check.sh and
# binds it with bin/fm-check-register.sh; the watcher runs it every sweep and
# `check` does real work only when the last run is 7 days old
# (<state>/backlog-pruner.last). `check` prints nothing unless it moved items
# (or, when armed without --apply, would have) or found closable items, and
# that one line becomes the `check:` wake the drain presents. `arm` without
# --apply keeps the weekly run a dry run; `arm --apply` lets it move. `arm`
# again switches between the two.
#
# Switch off: `fm-backlog-pruner.sh disarm` removes the check and its trust
# file. Nothing else runs the pruner.
#
# Environment: FM_HOME, FM_DATA_OVERRIDE, FM_STATE_OVERRIDE as everywhere;
# FM_BACKLOG_PRUNER_DAYS (default 7); FM_BACKLOG_PRUNER_INTERVAL seconds
# between weekly runs (default 604800); FM_BACKLOG_PRUNER_LOOKUPS forge
# lookups per run (default 40, extra URLs are reported as unchecked);
# FM_BACKLOG_PRUNER_NOW epoch override for tests.
#
# Exit: 0 success, 1 a move or write failed (nothing moved on a refused move),
# 2 invalid usage or missing requirement.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-check-lib.sh"

BACKLOG="$DATA/backlog.md"
LEDGER="$STATE/backlog-pruner.seen"
STAMP="$STATE/backlog-pruner.last"
DAYS=${FM_BACKLOG_PRUNER_DAYS:-7}
INTERVAL=${FM_BACKLOG_PRUNER_INTERVAL:-604800}
LOOKUPS=${FM_BACKLOG_PRUNER_LOOKUPS:-40}

fail() {
  printf 'fm-backlog-pruner: %s\n' "$*" >&2
  exit "${2:-2}"
}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

now_epoch() {
  printf '%s\n' "${FM_BACKLOG_PRUNER_NOW:-$(date +%s)}"
}

date_epoch() {  # <YYYY-MM-DD> -> epoch at 00:00 UTC, empty when unreadable
  date -u -d "$1 00:00:00" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s 2>/dev/null
}

uint_valid() {  # <value>
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -gt 0 ]
}

scan_backlog() {  # <workdir>: writes items.tsv and block/<id>
  mkdir -p "$1/block"
  awk -v dir="$1/block" -v out="$1/items.tsv" '
    function flush() {
      if (id != "") {
        printf "%s\037%s\037%s\037%s\037%s\n", id, section, since, held, blocked >> out
        close(dir "/" id)
      }
      id = ""
    }
    /^## / {
      flush()
      section = ($0 == "## In flight") ? "in_flight" : ($0 == "## Queued") ? "queued" : ""
      next
    }
    section == "" { next }
    /^- \[[ xX]\] [^ ]+ - / {
      flush()
      line = $0
      sub(/^- \[[ xX]\] /, "", line)
      id = line
      sub(/ .*/, "", id)
      since = ""
      if (match(line, /\(since [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)/)) {
        since = substr(line, RSTART + 7, 10)
      }
      held = (line ~ /\(hold:/) ? 1 : 0
      blocked = ""
      rest = line
      while (match(rest, /blocked-by: [^ ]+/)) {
        dep = substr(rest, RSTART + 12, RLENGTH - 12)
        blocked = blocked (blocked == "" ? "" : ",") dep
        rest = substr(rest, RSTART + RLENGTH)
      }
      print $0 > (dir "/" id)
      next
    }
    id != "" { print $0 >> (dir "/" id) }
    END { flush() }
  ' "$BACKLOG"
  : >> "$1/items.tsv"
}

item_hash() {  # <workdir> <id>
  fm_custom_check_sha256 "$1/block/$2"
}

ledger_epoch() {  # <id> <hash> -> epoch recorded for that exact content, empty when none
  [ -f "$LEDGER" ] || return 0
  awk -F '\t' -v id="$1" -v hash="$2" '$1 == id && $2 == hash { print $3; exit }' "$LEDGER"
}

ledger_knows() {  # <id>
  [ -f "$LEDGER" ] && awk -F '\t' -v id="$1" '$1 == id { found = 1 } END { exit !found }' "$LEDGER"
}

last_change_epoch() {  # <id> <hash> <since> <now>
  local recorded since_epoch=
  if [ -n "$3" ]; then since_epoch=$(date_epoch "$3"); fi
  recorded=$(ledger_epoch "$1" "$2")
  if [ -n "$recorded" ]; then
    printf '%s\n' "$recorded"
  elif ledger_knows "$1" || [ -z "$since_epoch" ]; then
    printf '%s\n' "$4"
  else
    printf '%s\n' "$since_epoch"
  fi
}

pr_urls() {  # <block-file> -> one distinct, parseable change URL per line
  local url
  grep -oE 'https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+/(pull/[0-9]+|-/merge_requests/[0-9]+)' "$1" 2>/dev/null \
    | sort -u | while IFS= read -r url; do
        fm_pr_url_parse "$url" && printf '%s\n' "$url"
      done
}

PR_CACHE=
PR_LOOKUPS_USED=0
UNCHECKED=0

pr_merged() {  # <url> -> 0 merged, 1 not merged or unknown
  local url=$1 cached
  cached=$(printf '%s\n' "$PR_CACHE" | awk -F '\t' -v u="$url" '$1 == u { print $2; exit }')
  if [ -z "$cached" ]; then
    if [ "$PR_LOOKUPS_USED" -ge "$LOOKUPS" ]; then
      UNCHECKED=$((UNCHECKED + 1))
      return 1
    fi
    PR_LOOKUPS_USED=$((PR_LOOKUPS_USED + 1))
    cached=unknown
    if fm_pr_url_parse "$url"; then
      case "$FM_PR_PROVIDER" in
        github) fm_pr_github_read_record "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER" \
          && cached=$FM_PR_RECORD_MERGED ;;
        gitlab) fm_pr_gitlab_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
          && cached=$FM_PR_RECORD_MERGED ;;
      esac
    fi
    PR_CACHE="$PR_CACHE$url	$cached
"
  fi
  [ "$cached" = true ]
}

item_title() {  # <workdir> <id>
  head -n 1 "$1/block/$2" | sed -e 's/^- \[[ xX]\] [^ ]* - //' -e 's/ blocked-by: [^ ]*//g' \
    -e 's/ (repo: [^)]*)//' -e 's/ (kind: [^)]*)//' -e 's/ (since [^)]*)//' | cut -c1-120
}

analyse() {  # <workdir> <now>: writes verdict.tsv (id, verdict, since, detail) and current.ledger
  local work=$1 now=$2 cutoff id section since held blocked hash last urls url all_merged dep changed a b
  cutoff=$((now - DAYS * 86400))
  : > "$work/verdict.tsv"
  : > "$work/current.ledger"
  while IFS=$'\037' read -r id section since held blocked; do
    hash=$(item_hash "$work" "$id") || fail "no sha256 tool available"
    last=$(last_change_epoch "$id" "$hash" "$since" "$now")
    printf '%s\t%s\t%s\n' "$id" "$hash" "$last" >> "$work/current.ledger"
    if [ "$held" = 1 ]; then
      printf '%s\037keep:held\037%s\037\n' "$id" "$since" >> "$work/verdict.tsv"; continue
    fi
    urls=$(pr_urls "$work/block/$id" | tr '\n' ' ')
    urls=${urls% }
    if [ -n "$urls" ]; then
      all_merged=1
      for url in $urls; do pr_merged "$url" || { all_merged=0; break; }; done
      if [ "$all_merged" = 1 ]; then
        printf '%s\037close:%s\037%s\037%s\n' "$id" "$section" "$since" "$urls" >> "$work/verdict.tsv"; continue
      fi
    fi
    if [ "$section" = in_flight ]; then
      printf '%s\037keep:in-flight\037%s\037\n' "$id" "$since" >> "$work/verdict.tsv"
    elif [ "$last" -gt "$cutoff" ]; then
      printf '%s\037keep:recent\037%s\037\n' "$id" "$since" >> "$work/verdict.tsv"
    else
      printf '%s\037fog\037%s\037\n' "$id" "$since" >> "$work/verdict.tsv"
    fi
  done < "$work/items.tsv"

  changed=1
  while [ "$changed" = 1 ]; do
    changed=0
    while IFS=$'\037' read -r id section since held blocked; do
      [ -n "$blocked" ] || continue
      for dep in ${blocked//,/ }; do
        awk -F '\037' -v i="$dep" '$1 == i { found = 1 } END { exit !found }' "$work/verdict.tsv" || continue
        a=$(awk -F '\037' -v i="$id" '$1 == i { print $2 }' "$work/verdict.tsv")
        b=$(awk -F '\037' -v i="$dep" '$1 == i { print $2 }' "$work/verdict.tsv")
        if [ "$a" = fog ] && [ "$b" != fog ]; then
          awk -F '\037' -v OFS='\037' -v i="$id" '$1 == i { $2 = "keep:dependency" } { print }' \
            "$work/verdict.tsv" > "$work/verdict.next" && mv "$work/verdict.next" "$work/verdict.tsv"
          changed=1
        elif [ "$b" = fog ] && [ "$a" != fog ]; then
          awk -F '\037' -v OFS='\037' -v i="$dep" '$1 == i { $2 = "keep:dependency" } { print }' \
            "$work/verdict.tsv" > "$work/verdict.next" && mv "$work/verdict.next" "$work/verdict.tsv"
          changed=1
        fi
      done
    done < "$work/items.tsv"
  done
}

write_report() {  # <workdir> <report-file> <mode> <now> <fog-file> <moved: yes|no>
  local work=$1 report=$2 mode=$3 now=$4 fog=$5 moved=$6 id verdict since detail label
  {
    printf '# Backlog pruner report\n\n'
    printf -- '- Run: %s UTC, mode %s, window %s days\n' "$(date -u -d "@$now" '+%Y-%m-%d %H:%M' 2>/dev/null || date -u -r "$now" '+%Y-%m-%d %H:%M')" "$mode" "$DAYS"
    printf -- '- Fog file: %s\n' "$fog"
    printf -- '- Kept: %s item(s). To fog: %s. Reported for closing: %s. PR lookups unchecked: %s.\n\n' \
      "$(awk -F '\037' '$2 ~ /^keep:/ { n++ } END { print n + 0 }' "$work/verdict.tsv")" \
      "$(awk -F '\037' '$2 == "fog" { n++ } END { print n + 0 }' "$work/verdict.tsv")" \
      "$(awk -F '\037' '$2 ~ /^close:/ { n++ } END { print n + 0 }' "$work/verdict.tsv")" "$UNCHECKED"
    if [ "$moved" = yes ]; then label='Moved to the fog'; else label='Would move to the fog (dry run)'; fi
    printf '## %s\n\n' "$label"
    while IFS=$'\037' read -r id verdict since detail; do
      [ "$verdict" = fog ] || continue
      printf -- '- %s (since %s) - %s\n' "$id" "${since:-unknown}" "$(item_title "$work" "$id")"
    done < "$work/verdict.tsv"
    printf '\n## Cite only merged PRs: close or keep\n\n'
    while IFS=$'\037' read -r id verdict since detail; do
      case "$verdict" in close:*) ;; *) continue ;; esac
      printf -- '- %s (%s) - %s - %s\n' "$id" "${verdict#close:}" "$detail" "$(item_title "$work" "$id")"
    done < "$work/verdict.tsv"
  } > "$report"
}

ledger_publish() {  # <workdir>
  local tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  [ ! -L "$LEDGER" ] || return 1
  tmp=$(mktemp "$STATE/.backlog-pruner.XXXXXX") || return 1
  cp "$1/current.ledger" "$tmp" && mv -f -- "$tmp" "$LEDGER" || { rm -f -- "$tmp"; return 1; }
}

do_run() {  # <apply: 0|1> <report-file> <fog-file> <refresh-ledger: 0|1>
  local apply=$1 report=$2 fog=$3 refresh=$4 work now mv_out moved=no mode ids
  [ -f "$BACKLOG" ] && [ ! -L "$BACKLOG" ] || fail "no markdown backlog at $BACKLOG" 2
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required to move items" 2
  now=$(now_epoch)
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-backlog-pruner.XXXXXX") || fail "cannot create a work directory" 1
  # shellcheck disable=SC2064
  trap "rm -rf -- '$work'" EXIT
  scan_backlog "$work"
  analyse "$work" "$now"
  ids=$(awk -F '\037' '$2 == "fog" { print $1 }' "$work/verdict.tsv" | tr '\n' ' ')
  mode="dry run"
  if [ "$apply" = 1 ]; then
    mode=apply
    if [ -n "$ids" ]; then
      # shellcheck disable=SC2086
      if ! mv_out=$("$SCRIPT_DIR/fm-tasks-axi.sh" mv $ids --to "$fog" 2>&1); then
        printf 'fm-backlog-pruner: tasks-axi refused the move; nothing moved:\n%s\n' "$mv_out" >&2
        return 1
      fi
      moved=yes
    fi
  fi
  write_report "$work" "$report" "$mode" "$now" "$fog" "$moved" || fail "cannot write $report" 1
  if [ "$refresh" = 1 ]; then
    if [ "$moved" = yes ]; then
      drop_moved_from_ledger "$work"
    fi
    ledger_publish "$work" || printf 'fm-backlog-pruner: could not update %s\n' "$LEDGER" >&2
  fi
  RUN_FOG=$(awk -F '\037' '$2 == "fog" { n++ } END { print n + 0 }' "$work/verdict.tsv")
  RUN_CLOSE=$(awk -F '\037' '$2 ~ /^close:/ { n++ } END { print n + 0 }' "$work/verdict.tsv")
  RUN_CLOSE_IDS=$(awk -F '\037' '$2 ~ /^close:/ { printf "%s%s", sep, $1 " " $4; sep = "; " }' "$work/verdict.tsv")
  rm -rf -- "$work"
  trap - EXIT
}

drop_moved_from_ledger() {  # <workdir>
  local work=$1 id
  for id in $(awk -F '\037' '$2 == "fog" { print $1 }' "$work/verdict.tsv"); do
    awk -F '\t' -v OFS='\t' -v i="$id" '$1 != i' "$work/current.ledger" > "$work/current.next" \
      && mv "$work/current.next" "$work/current.ledger"
  done
}

summary_line() {
  local verb=$1
  printf 'backlog-pruner: %s %s item(s) to the fog' "$verb" "$RUN_FOG"
  if [ "$RUN_CLOSE" -gt 0 ]; then
    printf '; %s item(s) cite only merged PRs and need closing: %s' "$RUN_CLOSE" "$RUN_CLOSE_IDS"
  fi
  printf '; report %s\n' "$REPORT_FILE"
}

cmd_run() {
  local apply=0 fog="$DATA/backlog-fog.md"
  REPORT_FILE="$DATA/backlog-prune-report.md"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      --days) shift; uint_valid "${1:-}" || fail "--days needs a positive number"; DAYS=$1 ;;
      --report-file) shift; [ -n "${1:-}" ] || fail "--report-file needs a path"; REPORT_FILE=$1 ;;
      --fog) shift; [ -n "${1:-}" ] || fail "--fog needs a path"; fog=$1 ;;
      *) fail "unknown option '$1'" ;;
    esac
    shift
  done
  do_run "$apply" "$REPORT_FILE" "$fog" "$apply" || exit 1
  if [ "$apply" = 1 ]; then summary_line moved; else summary_line "would move"; fi
}

cmd_check() {
  local apply=0 last now
  [ "${1:-}" != --apply ] || apply=1
  now=$(now_epoch)
  last=0
  [ -f "$STAMP" ] && [ ! -L "$STAMP" ] && last=$(cat "$STAMP" 2>/dev/null)
  uint_valid "$last" || last=0
  [ $((now - last)) -ge "$INTERVAL" ] || exit 0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
  REPORT_FILE="$DATA/backlog-prune-report.md"
  printf '%s\n' "$now" > "$STAMP" || exit 0
  if ! do_run "$apply" "$REPORT_FILE" "$DATA/backlog-fog.md" 1; then
    printf 'backlog-pruner: the weekly run failed; see bin/fm-backlog-pruner.sh run for the reason\n'
    exit 0
  fi
  [ "$RUN_FOG" -gt 0 ] || [ "$RUN_CLOSE" -gt 0 ] || exit 0
  if [ "$apply" = 1 ]; then summary_line moved; else summary_line "would move"; fi
}

cmd_arm() {
  local apply=0 staged device
  local -a shim
  case "${1:-}" in
    '') ;;
    --apply) apply=1 ;;
    *) fail "unknown option '$1'" ;;
  esac
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable" 1
  device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable" 1
  fm_pr_regular_destination_on_device_or_absent "$STATE/backlog-pruner.check.sh" "$device" \
    || fail "unsafe check destination" 1
  staged=$(umask 077; mktemp "$STATE/.backlog-pruner-check.XXXXXX") || fail "cannot stage the check" 1
  shim=('#!/usr/bin/env bash'
    "export FM_HOME=$(printf '%q' "$FM_HOME")"
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")"
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")")
  if [ "$apply" = 1 ]; then
    shim+=("exec $(printf '%q' "$SCRIPT_DIR/fm-backlog-pruner.sh") check --apply")
  else
    shim+=("exec $(printf '%q' "$SCRIPT_DIR/fm-backlog-pruner.sh") check")
  fi
  printf '%s\n' "${shim[@]}" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/backlog-pruner.check.sh"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" backlog-pruner
}

cmd_disarm() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" backlog-pruner
}

uint_valid "$DAYS" && uint_valid "$INTERVAL" && uint_valid "$LOOKUPS" || fail "invalid numeric setting in the environment"

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  check) shift; cmd_check "$@" ;;
  arm) shift; cmd_arm "$@" ;;
  disarm) cmd_disarm ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
