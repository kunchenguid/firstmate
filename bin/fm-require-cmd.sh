#!/usr/bin/env bash
# Resolve a command to a runnable executable, run it, and verify its final artifact.
# Prints the resolved executable path on stdout before running anything, so a
# caller that only needs the path captures it with --resolve-only.
#
# Resolution order, most authoritative first:
#   1. PATH, via command -v.
#   2. A command containing a slash, taken as a path as written.
#   3. ~/.local/bin.
#   4. The npm exec cache, ~/.npm/_npx/*/node_modules/.bin, where an `npx <cmd>`
#      package that was never installed globally still keeps a runnable binary.
# An unresolved command exits 127 with a diagnostic naming every location it
# searched, because the alternative a caller otherwise takes - reading the
# shell's own "command not found", then reporting on anyway - is what ends a
# task with neither a result nor a reason.
#
# --expect-artifact makes completion depend on the artifact rather than on the
# command's exit status or on a timeout: a tool that exits 0 after analysis but
# writes nothing still fails here. A file must exist and be non-empty; a
# directory must exist and hold at least one entry.
#
# Usage: fm-require-cmd.sh [--resolve-only] [--expect-artifact <path>] <command> [args...]
set -eu

usage() {
  echo "usage: fm-require-cmd.sh [--resolve-only] [--expect-artifact <path>] <command> [args...]" >&2
}

RESOLVE_ONLY=0
ARTIFACT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolve-only)
      RESOLVE_ONLY=1
      ;;
    --expect-artifact)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      ARTIFACT=$2
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "fm-require-cmd.sh: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
  shift
done

[ "$#" -ge 1 ] || { usage; exit 1; }
CMD=$1
shift

PATH_DIRS=()
if [ -n "${PATH:-}" ]; then
  PATH_REST=$PATH
  while :; do
    PATH_DIRS+=("${PATH_REST%%:*}")
    [ "$PATH_REST" = "${PATH_REST#*:}" ] && break
    PATH_REST=${PATH_REST#*:}
  done
fi
SEARCH=("${HOME:-}/.local/bin")
for bin in "${HOME:-}"/.npm/_npx/*/node_modules/.bin; do
  [ -d "$bin" ] || continue
  SEARCH+=("$bin")
done

EXE=""
case "$CMD" in
  */*)
    if [ -f "$CMD" ] && [ -x "$CMD" ]; then
      EXE=$CMD
    fi
    ;;
  *)
    found=$(command -v "$CMD" 2>/dev/null) || found=""
    if [ -n "$found" ] && [ -f "$found" ] && [ -x "$found" ]; then
      EXE=$found
    else
      for dir in "${SEARCH[@]}"; do
        if [ -x "$dir/$CMD" ] && [ ! -d "$dir/$CMD" ]; then
          EXE="$dir/$CMD"
          break
        fi
      done
    fi
    ;;
esac

if [ -z "$EXE" ]; then
  case "$CMD" in
    */*)
      echo "fm-require-cmd.sh: $CMD: not an executable file" >&2
      ;;
    *)
      PRETTY=""
      for dir in "${PATH_DIRS[@]}" "${SEARCH[@]}"; do
        [ -n "$dir" ] || dir=$PWD
        PRETTY="$PRETTY${PRETTY:+, }$dir"
      done
      {
        echo "fm-require-cmd.sh: $CMD: no executable found"
        echo "fm-require-cmd.sh: searched: $PRETTY"
        echo "fm-require-cmd.sh: install $CMD and put it on PATH"
      } >&2
      ;;
  esac
  exit 127
fi

printf '%s\n' "$EXE"
[ "$RESOLVE_ONLY" -eq 0 ] || exit 0

set +e
"$EXE" "$@"
STATUS=$?
set -e
[ "$STATUS" -eq 0 ] || exit "$STATUS"

if [ -n "$ARTIFACT" ]; then
  OK=1
  if [ -d "$ARTIFACT" ]; then
    [ -n "$(ls -A -- "$ARTIFACT" 2>/dev/null)" ] || OK=0
  else
    [ -s "$ARTIFACT" ] || OK=0
  fi
  if [ "$OK" -ne 1 ]; then
    echo "fm-require-cmd.sh: $CMD exited 0 but produced no artifact at $ARTIFACT; the run is not complete" >&2
    exit 1
  fi
  printf 'fm-require-cmd.sh: verified %s\n' "$ARTIFACT" >&2
fi
