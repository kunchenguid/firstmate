#!/usr/bin/env bash
# fm-stdlib.sh - the shared canonical definitions for firstmate bin scripts.
#
# ponytail: one definition each for helpers previously copy-pasted across
# bin/; a script converts by deleting its local copy and sourcing this file.
#
# Source only, no side effects on source, set -u / set -e safe. A function
# earns a place here only when at least two scripts want the exact same body;
# near-miss variants stay local to their owner instead of growing flags.

die() {  # <message>: print "error: <message>" to stderr, exit 1
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage_render_header() {  # <script-file>: print its leading comment block
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$1"
}

sha256_file() {  # <path>: hex SHA-256 digest of the file
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

json_escape() {  # <text>: JSON string content, newlines become spaces
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

path_is_ancestor_of() {  # <ancestor> <path>: 0 when ancestor strictly contains path
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

default_branch() {  # <dir>: the repo's default branch name
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

now_ms() {  # epoch milliseconds
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

meta_value() {  # <meta-file> <key>: last value recorded for key, empty when absent
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
