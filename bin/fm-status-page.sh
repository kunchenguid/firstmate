#!/usr/bin/env bash
# fm-status-page.sh - render the static local task-status HTML projection.
#
# Usage: fm-status-page.sh
#
# Reads only the canonical task and seat JSON owners, then atomically writes
# data/status-page.html. FM_STATUS_PAGE_OUTPUT and FM_STATUS_PAGE_NOW are test
# seams; production callers use the default output and current UTC time.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
OUTPUT="${FM_STATUS_PAGE_OUTPUT:-$DATA/status-page.html}"
NOW="${FM_STATUS_PAGE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
FLEET_SNAPSHOT="${FM_STATUS_PAGE_FLEET_SNAPSHOT:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
BEARINGS_SNAPSHOT="${FM_STATUS_PAGE_BEARINGS_SNAPSHOT:-$SCRIPT_DIR/fm-bearings-snapshot.sh}"

command -v jq >/dev/null 2>&1 || { echo "fm-status-page: jq is required" >&2; exit 1; }
NOW_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW" +%s 2>/dev/null \
  || date -u -d "$NOW" +%s 2>/dev/null) || {
  echo "fm-status-page: FM_STATUS_PAGE_NOW must be an ISO-8601 UTC timestamp" >&2
  exit 1
}

INPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-status-page.XXXXXX") || exit 1
trap 'rm -rf "$INPUT_DIR"' EXIT
"$FLEET_SNAPSHOT" --json > "$INPUT_DIR/tasks.json" || exit $?
"$BEARINGS_SNAPSHOT" --json --all-secondmates > "$INPUT_DIR/bearings.json" || exit $?

html=$(jq -nr \
  --arg generated "$NOW" \
  --argjson now_epoch "$NOW_EPOCH" \
  --slurpfile task_data "$INPUT_DIR/tasks.json" \
  --slurpfile bearings_data "$INPUT_DIR/bearings.json" '
  def esc:
    tostring
    | gsub("&"; "&amp;")
    | gsub("<"; "&lt;")
    | gsub(">"; "&gt;")
    | gsub("\\\""; "&quot;");
  def trim($n):
    tostring | gsub("\\s+"; " ")
    | if length > $n then .[:$n] + "…" else . end;
  def duration($seconds):
    if $seconds == null or $seconds < 0 then "age unknown"
    elif $seconds < 60 then ($seconds | floor | tostring) + "s"
    elif $seconds < 3600 then (($seconds / 60 | floor | tostring) + "m")
    elif $seconds < 86400 then (($seconds / 3600 | floor | tostring) + "h")
    else (($seconds / 86400 | floor | tostring) + "d") end;
  def timestamp_epoch($raw):
    if ($raw | test("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")) then
      ($raw | capture("(?<value>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)").value | fromdateiso8601)
    else null end;
  def column($task):
    ($task.current_state.state // "") as $current
    | if any(($task.hints.open_decisions // [])[]?; .verb == "needs-decision") then "needs-decision"
    elif $current == "parked" then "needs-decision"
    elif $current == "blocked" then "blocked"
    elif $current == "working" then "working"
    elif $current == "paused" then "paused"
    elif $current == "failed" then "blocked"
    elif $current == "done" then "done-awaiting-merge"
    else "unknown" end;
  def status_age($task):
    ($task.paths.status_log.last_event.raw // "") as $raw
    | (timestamp_epoch($raw)) as $timestamp
    | if $timestamp != null and $timestamp <= $now_epoch then
        {label:((duration($now_epoch - $timestamp)) + " · timestamp")}
      elif ($task.paths.status_log.mtime_epoch // null) != null then
        {label:((duration($now_epoch - $task.paths.status_log.mtime_epoch)) + " · status file mtime")}
      else {label:"age unknown"} end;
  def card($task):
    ($task.paths.status_log.last_event.raw // $task.current_state.detail // $task.current_state.state // "unknown") as $status
    | (status_age($task).label) as $age
    | ((if ($task.code // "") == "" then "" else "[" + $task.code + "] " end) + ($task.backlog.title // $task.id)) as $heading
    | "<article class=\"card\"><h3>\($heading | esc)</h3><dl><dt>Repository</dt><dd>\(($task.backlog.repo // $task.project // "unknown") | esc)</dd><dt>Agent</dt><dd>\((($task.harness // "unknown") + " / " + ($task.model // "unknown")) | esc)</dd><dt>Status</dt><dd>\(($status | trim(160)) | esc)</dd><dt>Age</dt><dd>\($age | esc)</dd></dl></article>";
  def status_column($snapshot; $id; $title):
    ([ $snapshot.tasks[]? | select(.kind != "secondmate" and column(.) == $id) ]) as $items
    | "<section class=\"column\"><h2>\($title) <span>\($items | length)</span></h2><div class=\"cards\">"
      + (if ($items | length) == 0 then "<p class=\"empty\">No items.</p>" else ($items | map(card(.)) | join("")) end)
      + "</div></section>";
  def seats($snapshot):
    ($snapshot.secondmates // []) as $items
    | "<section class=\"seats\"><h2>Agent seats</h2><div class=\"seat-list\">"
      + (if ($items | length) == 0 then "<p class=\"empty\">No registered agent seats.</p>"
         else ($items | map("<article class=\"seat\"><strong>\(.id | esc)</strong><span>\((.state // "unknown") | esc)</span><small>\((.doing // .reason // "-") | trim(160) | esc)</small></article>") | join("")) end)
      + "</div></section>";
  ($task_data[0]) as $tasks
  | ($bearings_data[0]) as $bearings
  | "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Task status</title><style>"
  + ":root{color-scheme:light dark;--bg:#f5f7fb;--panel:#fff;--ink:#19212e;--muted:#5d6878;--line:#d9e0ea;--accent:#2563eb;--badge-ink:#fff}@media(prefers-color-scheme:dark){:root{--bg:#10151d;--panel:#18202b;--ink:#edf3fb;--muted:#aebbd0;--line:#324052;--accent:#8ab4ff;--badge-ink:#10151d}}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 system-ui,sans-serif}header,main{max-width:1500px;margin:auto;padding:24px}header{display:flex;gap:16px;justify-content:space-between;align-items:baseline}h1,h2,h3{margin:0}h1{font-size:1.6rem}h2{font-size:1rem}h2 span{font-size:.8rem;background:var(--accent);color:var(--badge-ink);border-radius:999px;padding:2px 8px}.stamp,.empty,dt,small{color:var(--muted)}.board{display:grid;grid-template-columns:repeat(6,minmax(230px,1fr));gap:16px;overflow-x:auto;padding-bottom:8px}.column,.seats{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px}.cards{display:grid;gap:10px;margin-top:12px}.card,.seat{border:1px solid var(--line);border-radius:9px;padding:12px}.card h3{font-size:.95rem;margin-bottom:8px}.card dl{display:grid;grid-template-columns:auto 1fr;gap:4px 8px;margin:0;font-size:.82rem}.card dd{margin:0;min-width:0;overflow-wrap:anywhere}.seats{margin-top:18px}.seat-list{display:grid;gap:8px;margin-top:10px}.seat{display:grid;grid-template-columns:minmax(120px,1fr) auto;gap:3px 12px}.seat small{grid-column:1/-1}@media(max-width:700px){header{display:block}header .stamp{margin-top:6px}main,header{padding:16px}}</style></head><body><header><h1>Task status</h1><p class=\"stamp\">Generated at \($generated | esc)</p></header><main><div class=\"board\">"
  + status_column($tasks; "needs-decision"; "Needs decision")
  + status_column($tasks; "blocked"; "Blocked")
  + status_column($tasks; "working"; "Working")
  + status_column($tasks; "paused"; "Paused")
  + status_column($tasks; "done-awaiting-merge"; "Done awaiting merge")
  + status_column($tasks; "unknown"; "Unknown")
  + "</div>" + seats($bearings) + "</main></body></html>"') || exit $?

mkdir -p "$(dirname "$OUTPUT")"
tmp=$(mktemp "$(dirname "$OUTPUT")/.status-page.XXXXXX")
trap 'rm -rf "$INPUT_DIR"; rm -f "$tmp"' EXIT
printf '%s\n' "$html" > "$tmp"
size=$(wc -c < "$tmp" | tr -d '[:space:]')
[ "$size" -lt 61440 ] || { echo "fm-status-page: output exceeds 60 KB" >&2; exit 1; }
chmod 0600 "$tmp"
mv -f "$tmp" "$OUTPUT"
rm -rf "$INPUT_DIR"
trap - EXIT
printf 'rendered: %s\n' "$OUTPUT"
