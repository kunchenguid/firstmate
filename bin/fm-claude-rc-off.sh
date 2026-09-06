#!/usr/bin/env bash
# Launch Claude with Remote Control disabled, or verify that policy in a Herdr pane.
# Usage: fm-claude-rc-off.sh launch [Claude arguments...]
#        fm-claude-rc-off.sh verify <session> <pane>
# Launch merges caller --settings JSON or files and forces disableRemoteControl=true.
# It requires Claude Code >= 2.1.128, the vendor's documented support floor.
# Settings are passed inline so the account's global settings remain unchanged.
# Verify reads the live foreground process arguments, never terminal history.
# It requires exactly one Claude process with one inline enforced settings object.
# Success verifies the launch policy, not an independent network-connection measurement.
# An existing unprotected session must be relaunched through launch; verify never types keys.
# Lab sessions are routed through fm-herdr-lab.sh, including read-only verification.
# The live drift guard is tests/fm-claude-rc-off-live-e2e.test.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() { printf 'fm-claude-rc-off: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

check_version() {
  local version major minor patch
  version=$(claude --version) || die 'cannot read Claude version'
  [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)[[:space:]]+\(Claude\ Code\)$ ]] || die "unrecognized Claude version: $version"
  major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
  (( major > 2 || (major == 2 && (minor > 1 || (minor == 1 && patch >= 128))) )) || die "Claude $version lacks the required disableRemoteControl setting"
}

launch() {
  local settings='{}' value parsed
  local -a args=()
  check_version
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --settings)
        [ "$#" -ge 2 ] || die '--settings requires a value'
        value=$2
        shift 2
        ;;
      --settings=*) value=${1#*=}; shift ;;
      --) args+=("$@"); break ;;
      *) args+=("$1"); shift; continue ;;
    esac
    if [[ "$value" =~ ^[[:space:]]*\{ ]]; then
      parsed=$(printf '%s' "$value" | jq -ce 'select(type == "object")') || die 'invalid settings JSON'
    else
      parsed=$(jq -ce 'select(type == "object")' -- "$value") || die "cannot read settings object: $value"
    fi
    settings=$(jq -cn --argjson previous "$settings" --argjson next "$parsed" '$previous * $next')
  done
  settings=$(printf '%s' "$settings" | jq -c '.disableRemoteControl = true')
  exec claude --settings "$settings" "${args[@]}"
}

verify() {
  [ "$#" -eq 2 ] || die 'verify requires an explicit session and pane'
  local session=$1 pane=$2 info pid
  [ -n "$session" ] && [ -n "$pane" ] || die 'session and pane must not be empty'
  case "$session" in
    fm-lab-*) info=$("$ROOT/bin/fm-herdr-lab.sh" run "$session" pane process-info --pane "$pane") ;;
    *) info=$(herdr pane process-info --pane "$pane" --session "$session") ;;
  esac
  pid=$(printf '%s' "$info" | jq -er --arg pane "$pane" '
    .result.process_info | select(.pane_id == $pane)
    | [.foreground_processes[]? | select(.argv | type == "array")
       | select(.argv[0] | type == "string")
       | select((.argv[0] | split("/") | last) == "claude")]
    | select(length == 1) | .[0] as $process
    | $process.argv as $all
    | ($all | index("--")) as $end
    | ($all[:($end // ($all | length))]) as $args
    | [$args | to_entries[] | select(.value == "--settings" or (.value | startswith("--settings=")))
       | if .value == "--settings" then $args[.key + 1] else .value[11:] end]
    | select(length == 1) | .[0] | fromjson
    | select(type == "object" and .disableRemoteControl == true)
    | $process.pid | select(type == "number" and . > 0)
  ') || die "RC-off policy NOT verified for $session/$pane; relaunch Claude through this helper"
  printf 'RC-off launch policy verified: session=%s pane=%s pid=%s disableRemoteControl=true\n' "$session" "$pane" "$pid"
}

case "${1:-}" in
  launch) shift; launch "$@" ;;
  verify) shift; verify "$@" ;;
  --help|-h|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
