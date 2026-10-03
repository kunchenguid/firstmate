#!/usr/bin/env bash
# herdr-checklist.sh - the Herdr checklist plugin's command entrypoints.
#
# Herdr launches these from herdr-plugin.toml (argv arrays, no shell), with the
# plugin directory as the working directory and the plugin runtime environment
# set. Subcommands:
#   view   Pane entrypoint. Watch the checklist file and re-render it on change.
#   new    Action. Scaffold a checklist file (format: checklist-template.md) and
#          print how to open its pane.
#
# The checklist file is $HERDR_CHECKLIST_FILE if set (use an absolute path),
# else CHECKLIST.md under $HERDR_PLUGIN_STATE_DIR (Herdr-provided). The starter
# owner name comes from $HERDR_CHECKLIST_OWNER (default "you").
#
# Rendering: glow, mdcat, or bat if any is on PATH, otherwise plain cat. Force a
# choice with $HERDR_CHECKLIST_RENDERER (a program name). No required
# dependencies beyond bash and coreutils (cksum).

RENDERERS=(glow mdcat bat)

warn() { printf '%s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }

# Shared path resolution: the pane and action agree when they receive the same
# environment. See README.md for server setup and pane-only overrides.
resolve_file() {
  if [ -n "${HERDR_CHECKLIST_FILE:-}" ]; then
    printf '%s\n' "$HERDR_CHECKLIST_FILE"
    return
  fi
  local base=${HERDR_PLUGIN_STATE_DIR:-${HERDR_PLUGIN_CONFIG_DIR:-$PWD}}
  printf '%s/CHECKLIST.md\n' "$base"
}

# A content fingerprint, not a timestamp: cksum reads the bytes, so an edit is
# detected even when it lands in the same second and keeps the same size (which
# whole-second mtime comparison would miss). "missing" when the file is absent.
fingerprint() {
  if [ -f "$1" ]; then
    cksum < "$1"
  else
    printf 'missing'
  fi
}

# Echo the renderer program: the override if set, else the first candidate on
# PATH, else "cat".
pick_renderer() {
  if [ -n "${HERDR_CHECKLIST_RENDERER:-}" ]; then
    printf '%s\n' "$HERDR_CHECKLIST_RENDERER"
    return
  fi
  local c
  for c in "$@"; do
    if command -v "$c" >/dev/null 2>&1; then
      printf '%s\n' "$c"
      return
    fi
  done
  printf '%s\n' cat
}

clear_screen() { printf '\033[H\033[2J'; }

render() {
  local file=$1 renderer
  renderer=$(pick_renderer "${RENDERERS[@]}")
  clear_screen
  if [ ! -f "$file" ]; then
    printf 'No checklist yet at %s\n\nCreate one with:\n  %s plugin action invoke %s.new\n' \
      "$file" "${HERDR_BIN_PATH:-herdr}" "${HERDR_PLUGIN_ID:-herdr-checklist}"
    return 1
  fi
  case $renderer in
    glow) glow -w "${COLUMNS:-100}" "$file" ;;
    bat) bat --style=plain --language=markdown --paging=never "$file" ;;
    cat) cat "$file" ;;
    *) "$renderer" "$file" ;;
  esac
}

# ponytail: 1s content-fingerprint poll instead of an inotify/fswatch
# dependency. A checklist changes a few times an hour, so the poll is invisible;
# swap in entr/fswatch only if you ever need sub-second latency.
# Fingerprint and render the same snapshot so concurrent saves cannot cache
# unseen content; only a successful render commits its fingerprint.
view() {
  local file last="" now snapshot
  file=$(resolve_file)
  snapshot=$(mktemp)
  trap 'rm -f "$snapshot"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while :; do
    if cp "$file" "$snapshot" 2>/dev/null && now=$(fingerprint "$snapshot") && [ "$now" != "$last" ]; then
      last=""
      if render "$snapshot"; then
        last=$now
      fi
    fi
    sleep "${HERDR_CHECKLIST_INTERVAL:-1}"
  done
}

# Emit a fresh, empty checklist in the format checklist-template.md defines.
starter() {
  local owner=${1:-you} now
  now=$(date '+%Y-%m-%d %H:%M')
  cat <<EOF
# CHECKLIST — $owner    $now local
# ════════════════════════════════════════════════════════════

## 🔴 ACT NOW — only you can do these

## 🔵 IN FLIGHT — agents working right now

## 🟡 WAITING — parked on a word or an external event

## 🟢 RECENTLY DONE
EOF
}

new() {
  local file owner
  file=$(resolve_file)
  owner=${HERDR_CHECKLIST_OWNER:-you}
  if [ -e "$file" ]; then
    printf 'Checklist already exists: %s\n' "$file"
  else
    mkdir -p "$(dirname "$file")"
    starter "$owner" >"$file"
    printf 'Created checklist: %s\n' "$file"
  fi
  printf 'Open its pane with:\n  %s plugin pane open --plugin %s --entrypoint checklist\n' \
    "${HERDR_BIN_PATH:-herdr}" "${HERDR_PLUGIN_ID:-herdr-checklist}"
}

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  set -euo pipefail
  case ${1:-} in
    view) shift; view "$@" ;;
    new) shift; new "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown subcommand: $1 (try: view, new, --help)" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
