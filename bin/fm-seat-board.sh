#!/usr/bin/env bash
# A very lightweight, read-only local web page showing quota-axi's report for
# every Claude seat: bin/fm-seat.sh manages which seat NEW workers launch on,
# and this script just displays what quota-axi says every seat has left.
#
# Usage:
#   fm-seat-board.sh [serve] [--port <n>]
#   fm-seat-board.sh render
#
# serve   Default action. Regenerates the page into a scratch directory, at
#         most once every FM_SEAT_BOARD_CACHE_SECONDS (60), and serves it on
#         127.0.0.1 only through `python3 -m http.server`, until Ctrl-C. Prints
#         the URL on start, plus its port, which defaults to 4405.
# render  Prints one generated page to stdout and exits, using the same
#         per-seat cache. Used by the test suite and for a one-shot look
#         without starting a server.
#
# The page shows, per seat (the default login plus every named seat from
# bin/fm-seat.sh's own listing): the account email, each quota window's
# percent LEFT and reset time, extra-usage spend against its cap, any
# attention line quota-axi reports (not logged in, rate limited, ...) shown
# as-is, and which seat is active for new workers.
#
# Read-only: this script never switches, arms, or edits any seat setting. It
# only reads. Every quota read goes through bin/fm-seat-lib.sh's own
# fm_seat_quota_read, which passes --no-credential-refresh and never
# --allow-keychain-prompt, exactly as every other seat probe in this repo.
#
# Caching: the Claude quota endpoint rate-limits frequent polling, so each
# seat's quota-axi report is cached for FM_SEAT_BOARD_CACHE_SECONDS (default
# 60) under FM_SEAT_BOARD_CACHE_DIR (default ~/.cache/fm-seat-board). A page
# reload just re-reads that cache; only the background regeneration loop in
# `serve`, or a `render` call after the cache has expired, ever shells out to
# quota-axi again. No token or credential is ever read or printed here; only
# what quota-axi's own --full --json report already exposes as non-secret.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck disable=SC2034  # read by the sourced fm-seat-lib.sh functions
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-seat-lib.sh
. "$SCRIPT_DIR/fm-seat-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

FM_SEAT_BOARD_PORT_DEFAULT=4405
FM_SEAT_BOARD_CACHE_SECONDS=${FM_SEAT_BOARD_CACHE_SECONDS:-60}
FM_SEAT_BOARD_CACHE_DIR=${FM_SEAT_BOARD_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/fm-seat-board}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# html_escape <text>
html_escape() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  printf '%s' "$s"
}

# cache_key <seat-name>
# A filesystem-safe cache filename for one seat name.
cache_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
}

# file_age_seconds <path>
# Seconds since <path> was last written, or empty when it cannot be read.
file_age_seconds() {
  local path=$1 mtime now
  mtime=$(stat -f '%m' "$path" 2>/dev/null) || mtime=$(stat -c '%Y' "$path" 2>/dev/null) || return 1
  now=$(date +%s)
  printf '%s\n' "$((now - mtime))"
}

# seat_quota_cached <seat-name> <config-dir>
# This seat's quota-axi --full --json report, read at most once every
# FM_SEAT_BOARD_CACHE_SECONDS. Prints the cached or freshly read report, or
# nothing when neither a fresh read nor a usable cache file exists.
seat_quota_cached() {
  local name=$1 dir=$2 cache_file age out
  mkdir -p "$FM_SEAT_BOARD_CACHE_DIR" 2>/dev/null || true
  cache_file="$FM_SEAT_BOARD_CACHE_DIR/$(cache_key "$name").json"
  if [ -f "$cache_file" ]; then
    age=$(file_age_seconds "$cache_file") || age=$((FM_SEAT_BOARD_CACHE_SECONDS + 1))
    if [ "$age" -lt "$FM_SEAT_BOARD_CACHE_SECONDS" ]; then
      cat "$cache_file"
      return 0
    fi
  fi
  out=$(fm_seat_quota_read "$dir") || out=
  if [ -n "$out" ] && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$out" > "$cache_file.tmp" 2>/dev/null && mv "$cache_file.tmp" "$cache_file" 2>/dev/null
    printf '%s' "$out"
    return 0
  fi
  [ -f "$cache_file" ] && cat "$cache_file"
}

board_css() {
  cat <<'CSS'
body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; color: #1a1a1a; }
h1 { font-size: 1.4rem; }
.generated { color: #666; font-size: 0.85rem; }
section.seat { border: 1px solid #ccc; border-radius: 6px; padding: 0.75rem 1rem; margin-bottom: 1rem; }
section.seat h2 { font-size: 1.05rem; margin: 0 0 0.35rem; }
.active { color: #0a7a2f; font-weight: bold; font-size: 0.8rem; }
.account { color: #444; margin: 0.1rem 0; }
.attention { color: #b30000; font-weight: bold; }
table.windows { border-collapse: collapse; margin-top: 0.4rem; }
table.windows th, table.windows td { text-align: left; padding: 0.15rem 0.6rem 0.15rem 0; }
.extra { color: #444; }
CSS
}

# seat_section_html <seat-name> <active-seat-name>
seat_section_html() {
  local name=$1 active=$2 dir json marker email src state_err attention extra spent limit
  dir=$(fm_seat_config_dir "$name")
  json=$(seat_quota_cached "$name" "$dir")
  marker=
  [ "$name" != "$active" ] || marker=' <span class="active">active for new workers</span>'
  printf '<section class="seat">\n'
  printf '<h2>%s%s</h2>\n' "$(html_escape "$name")" "$marker"
  if [ -z "$json" ]; then
    printf '<p class="attention">no quota data (quota-axi unavailable or the read timed out)</p>\n'
    printf '</section>\n'
    return
  fi
  email=$(printf '%s' "$json" |
    jq -r '(.providers[]? | select(.provider == "claude") | .account.email // empty)' 2>/dev/null)
  src=$(printf '%s' "$json" |
    jq -r '(.providers[]? | select(.provider == "claude") | .source // empty)' 2>/dev/null)
  state_err=$(printf '%s' "$json" |
    jq -r '(.providers[]? | select(.provider == "claude") | .state.error // empty)' 2>/dev/null)
  [ -z "$email" ] || printf '<p class="account">%s</p>\n' "$(html_escape "$email")"
  if [ "$src" != oauth ]; then
    attention=$state_err
    [ -n "$attention" ] || attention='not logged in'
    printf '<p class="attention">%s</p>\n' "$(html_escape "$attention")"
  fi
  printf '<table class="windows">\n<tr><th>window</th><th>left</th><th>resets</th></tr>\n'
  while IFS=$'\t' read -r wid label pct resets; do
    [ -n "$wid" ] || continue
    printf '<tr><td>%s</td><td>%s%%</td><td>%s</td></tr>\n' \
      "$(html_escape "${label:-$wid}")" "$(html_escape "$pct")" "$(html_escape "$resets")"
  done < <(printf '%s' "$json" | jq -r '
    (.providers[]? | select(.provider == "claude") | .windows // [])[] |
    select(.id != "extra_usage") |
    [.id, (.label // .id), ((.percentRemaining // "") | tostring), (.resetsAt // "")] | @tsv
  ' 2>/dev/null)
  printf '</table>\n'
  extra=$(printf '%s' "$json" | jq -r '
    (.providers[]? | select(.provider == "claude") | .windows // [])[] |
    select(.id == "extra_usage") |
    [((.spentUsd // "") | tostring), ((.limitUsd // "") | tostring)] | @tsv
  ' 2>/dev/null | head -1)
  if [ -n "$extra" ]; then
    IFS=$'\t' read -r spent limit <<<"$extra"
    printf '<p class="extra">extra usage: $%s of $%s</p>\n' "$(html_escape "$spent")" "$(html_escape "$limit")"
  fi
  printf '</section>\n'
}

render_page() {
  local active name
  active=$(fm_seat_active)
  printf '<!DOCTYPE html>\n<html><head><meta charset="utf-8">\n'
  printf '<title>Claude seats</title>\n'
  printf '<meta http-equiv="refresh" content="%s">\n' "$FM_SEAT_BOARD_CACHE_SECONDS"
  printf '<style>%s</style>\n' "$(board_css)"
  printf '</head><body>\n'
  printf '<h1>Claude seats</h1>\n'
  printf '<p class="generated">generated %s</p>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  seat_section_html "$FM_SEAT_DEFAULT_NAME" "$active"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    seat_section_html "$name" "$active"
  done < <(fm_seat_list)
  printf '</body></html>\n'
}

cmd_render() {
  render_page
}

cmd_serve() {
  local port=$FM_SEAT_BOARD_PORT_DEFAULT docroot gen_pid=
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)
        port=${2:-}
        shift 2
        ;;
      *)
        usage
        ;;
    esac
  done
  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"
  command -v quota-axi >/dev/null 2>&1 || die "quota-axi not found"
  docroot=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-board.XXXXXX") || die "could not create a scratch directory"
  cleanup() {
    [ -z "${gen_pid:-}" ] || kill "$gen_pid" 2>/dev/null || true
    rm -rf "$docroot"
  }
  trap cleanup EXIT INT TERM
  render_page > "$docroot/index.html"
  (
    while true; do
      sleep "$FM_SEAT_BOARD_CACHE_SECONDS"
      render_page > "$docroot/index.html.tmp" && mv "$docroot/index.html.tmp" "$docroot/index.html"
    done
  ) &
  gen_pid=$!
  printf 'Seat board: http://127.0.0.1:%s/\n' "$port"
  printf 'Ctrl-C to stop.\n'
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$docroot"
}

case "${1:-serve}" in
  serve)
    shift || true
    cmd_serve "$@"
    ;;
  render)
    cmd_render
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage
    ;;
esac
