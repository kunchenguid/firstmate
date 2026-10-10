#!/usr/bin/env bash
# Update the rest of Kun's stack that firstmate installs on this host.
#
# Mechanical half of the stack step of the /updatefirstmate skill.
# bin/fm-update.sh owns firstmate itself and its secondmate homes; this script
# owns the tools firstmate's bootstrap installs from Kun's own releases, each
# through that tool's own update path:
#
#   no-mistakes                                    no-mistakes update
#   treehouse                                      treehouse update
#   gh-axi chrome-devtools-axi lavish-axi quota-axi <tool> update
#   tasks-axi                                      npm install -g tasks-axi@latest
#
# tasks-axi has no self-update verb (its `update` edits a backlog task), so it
# takes the npm path bin/fm-bootstrap.sh installs it with, and only when the
# copy PATH resolves lives under npm's own global root; any other install would
# gain a second, shadowed copy instead of an update.
#
# The list is fixed on purpose and is not configurable. Harness CLIs, the session
# backend (herdr, tmux, zellij, cmux, orca) that hosts live workers, system
# packages, and node/gh/git belong to the operator, not to firstmate, and the CI
# pins in bin/fm-install-*.sh are never read or changed here. A tool that is not
# on PATH is skipped rather than installed: installing is bootstrap's job.
#
# no-mistakes runs one daemon shared by every lane and home, and its update
# restarts that daemon. `no-mistakes update` already refuses while any pipeline
# run is active unless given --force; this script never passes --force or --yes,
# feeds every update an empty stdin so no prompt can be answered for the
# operator, and reports that refusal as deferred so a later pass retries it.
#
# Each update is bounded by FM_STACK_UPDATE_TIMEOUT seconds (default 300). It
# only changes this host: a remote secondmate's host keeps its own tools.
#
# Output is one line per tool, in fm-update.sh's per-target style:
#   <tool>: updated <old>..<new>
#   <tool>: already current (<version>)
#   <tool>: deferred: <reason>
#   <tool>: skipped: <reason>
# Versions are read with `<tool> --version` before and after, so the verdict
# never depends on a tool's own wording. Exit status is 0 once every line is
# printed; a deferred or skipped tool is a reported outcome, not an error.
#
# Usage: fm-stack-update.sh [--help]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

STACK_TOOLS="no-mistakes treehouse gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"

usage() { echo "usage: fm-stack-update.sh [--help]" >&2; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) usage; exit 2 ;;
esac

TIMEOUT=${FM_STACK_UPDATE_TIMEOUT:-300}
case "$TIMEOUT" in
  ''|0|*[!0-9]*) echo "fm-stack-update: FM_STACK_UPDATE_TIMEOUT must be a positive whole number of seconds" >&2; exit 2 ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-stack-update.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

tool_version() {  # <tool> -> first dotted version its --version prints
  fm_run_timed 10 "$1" --version </dev/null 2>/dev/null \
    | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?([-+.][0-9A-Za-z.-]*)?' | head -1
}

last_line() {  # <file> -> its last non-empty line, trimmed and capped
  awk 'NF { line = $0 } END { gsub(/^[ \t]+|[ \t]+$/, "", line); print substr(line, 1, 200) }' "$1"
}

# True when the tasks-axi PATH resolves is installed under npm's global root.
npm_global_install() {  # <tool>
  local root bin
  command -v npm >/dev/null 2>&1 || return 1
  root=$(fm_run_timed 30 npm root -g </dev/null 2>/dev/null) || return 1
  [ -n "$root" ] || return 1
  root=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  bin=$(command -v "$1") || return 1
  bin=$(realpath "$bin" 2>/dev/null || readlink -f "$bin" 2>/dev/null) || return 1
  case "$bin" in "$root"/*) return 0 ;; esac
  return 1
}

update_tool() {  # <tool>
  local tool=$1 old new rc out="$TMP/$1.out"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool: skipped: not installed"
    return 0
  fi
  old=$(tool_version "$tool")
  if [ -z "$old" ]; then
    echo "$tool: skipped: cannot read its version"
    return 0
  fi
  case "$tool" in
    tasks-axi)
      if ! npm_global_install "$tool"; then
        echo "$tool: skipped: not an npm global install; update it with the tool that installed it"
        return 0
      fi
      fm_run_timed "$TIMEOUT" npm install -g tasks-axi@latest </dev/null >"$out" 2>&1
      ;;
    *)
      fm_run_timed "$TIMEOUT" "$tool" update </dev/null >"$out" 2>&1
      ;;
  esac
  rc=$?
  new=$(tool_version "$tool")
  if [ -n "$new" ] && [ "$new" != "$old" ]; then
    if [ "$rc" -eq 0 ]; then
      echo "$tool: updated $old..$new"
    else
      echo "$tool: updated $old..$new, but the update reported: $(last_line "$out")"
    fi
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    echo "$tool: skipped: update timed out after ${TIMEOUT}s"
  elif [ "$tool" = no-mistakes ] && grep -q 'refusing update because .*active pipeline run' "$out"; then
    echo "$tool: deferred: pipeline runs are active on the shared daemon; rerun once they finish"
  elif [ "$rc" -ne 0 ]; then
    echo "$tool: skipped: update failed: $(last_line "$out")"
  elif grep -Eiq 'self-update unavailable|skipping update' "$out"; then
    echo "$tool: skipped: $(grep -Ei 'self-update unavailable|skipping update' "$out" | head -1 | cut -c1-200)"
  else
    echo "$tool: already current ($old)"
  fi
}

for tool in $STACK_TOOLS; do
  update_tool "$tool"
done
exit 0
