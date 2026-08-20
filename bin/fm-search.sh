#!/usr/bin/env bash
# fm-search.sh - read-only local search of an operational Firstmate home corpus.
#
# docs/configuration.md "Local knowledge search" owns why the default rg path
# masks the corpus and where this helper sits in the fleet's retrieval story.
#
# Search starts in the current directory, the same as ordinary rg. Run it from
# the operational home root (or pass paths) to cover private and hidden files.
# The search target never depends on the caller: stdin is closed, so ripgrep
# always walks cwd or the given paths instead of reading a pipe or socket,
# RIPGREP_CONFIG_PATH is dropped so operator rg config cannot remask the corpus,
# and --no-ignore keeps .ignore/.rgignore from remasking that same corpus.
# Secret-bearing files and bulk clone trees stay excluded by name at any depth,
# so the exclusions hold from any starting directory; permissions are not
# changed.
#
# Usage:
#   fm-search.sh [rg-options] PATTERN [PATH ...]
#   fm-search.sh --files
#   fm-search.sh -h | --help
#
# Exit status matches ripgrep: 0 match, 1 no match, 2 error.
# Requires rg on PATH.
set -u

usage() {
  printf '%s\n' \
    "usage: ${0##*/} [rg-options] PATTERN [PATH ...]" \
    '' \
    'Read-only local search of tracked project text plus gitignored data/,' \
    'state/, and config/ and hidden .agents/skills/.' \
    'Requires rg. Exit status matches ripgrep: 0 match, 1 no match, 2 error.' \
    'Always searches cwd or the given paths, never stdin, ignores' \
    'RIPGREP_CONFIG_PATH, and does not honor ignore files.' \
    '' \
    'Excluded by default, by name at any depth:' \
    '  .git/  projects/  .no-mistakes/  .env' \
    '  claude-account-profiles  cmux-socket-password' \
    '' \
    'Run from the operational home root, or pass paths. This is optional' \
    'retrieval, not a delivery gate.'
}

if [ $# -eq 0 ]; then
  usage >&2
  exit 2
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if ! command -v rg >/dev/null 2>&1; then
  printf '%s: rg is required on PATH\n' "${0##*/}" >&2
  exit 2
fi

unset RIPGREP_CONFIG_PATH

exec rg \
  --hidden \
  --no-ignore \
  --glob '!.git/' \
  --glob '!projects/' \
  --glob '!.no-mistakes/' \
  --glob '!.env' \
  --glob '!claude-account-profiles' \
  --glob '!cmux-socket-password' \
  "$@" </dev/null
