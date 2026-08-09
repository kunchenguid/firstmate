#!/usr/bin/env bash
# fm-conflict-marker-check.sh - refuse a tree whose tracked text files carry an
# unresolved git conflict marker. AGENTS.md is always-loaded instruction text, so
# a marker block landing there is silently authoritative to every session until a
# human notices; this is the deterministic guard that stops that class at CI.
#
# Usage:
#   fm-conflict-marker-check.sh [--repo <dir>]
#
# Exit status:
#   0  no tracked text file carries a conflict marker
#   1  at least one marker found (each offending "<path>:<line>: <text>" printed)
#   2  the check could not run (not a git repo, git unavailable)
#
# Checked forms, each anchored at the start of a line: the "<<<<<<< " ours header,
# the "||||||| " diff3 base header, and the ">>>>>>> " theirs footer. The bare
# "=======" separator is deliberately not a trigger on its own, because a
# seven-character setext heading underline in Markdown is exactly that string; a
# real conflict always leaves a header and a footer as well, so the separator adds
# no detection and only false positives. Every pattern is assembled at runtime
# from repeated characters so this script and its test never match themselves.
set -euo pipefail

die() {
  printf 'fm-conflict-marker-check: %s\n' "$1" >&2
  exit 2
}

# Pathspecs excluded from the sweep: files that legitimately embed literal marker
# text, such as a fixture that must reproduce a conflicted tree on disk. Prefer
# generating markers at runtime over adding an entry here, because an excluded
# path is no longer guarded. Same shape as the sibling invariant checks in
# .github/workflows/ci.yml: the exclusion is stated once, in the checker.
list_excluded_pathspecs() {
  :
}

repeat_char() {
  local char=$1 count=$2 out='' i=0
  while [ "$i" -lt "$count" ]; do
    out="$out$char"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

repo=.
while [ "$#" -gt 0 ]; do
  case $1 in
    --repo)
      [ "$#" -gt 1 ] || die "--repo requires a directory"
      repo=$2
      shift 2
      ;;
    -h | --help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0
      ;;
    *) die "unknown argument '$1'" ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is required"
[ -n "$repo" ] && [ -d "$repo" ] || die "not a directory: '$repo'"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: '$repo'"

ours=$(repeat_char '<' 7)
theirs=$(repeat_char '>' 7)
base=$(repeat_char '\|' 7)
pattern="^(${ours}|${theirs}|${base})( |\$)"

pathspecs=()
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  pathspecs+=(":(exclude)$spec")
done < <(list_excluded_pathspecs)

# -I skips binary files; --no-index would miss the tracked-only contract, so this
# deliberately sweeps exactly what git tracks.
hits=$(git -C "$repo" grep -I -n -E -e "$pattern" -- . "${pathspecs[@]+"${pathspecs[@]}"}" || true)

if [ -n "$hits" ]; then
  printf 'fm-conflict-marker-check: unresolved conflict markers in tracked files:\n' >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi

printf 'fm-conflict-marker-check: no conflict markers in tracked files\n'
exit 0
