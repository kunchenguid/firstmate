#!/usr/bin/env bash
# Resolve a project's delivery mode, yolo flag, and base branch from the
# data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# With --base, prints the recorded base branch instead, or nothing when the
# project has no base= record (callers fall back to the repo's default branch).
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [<mode> base=<branch>] - <desc> ...       -> <mode> off, base <branch>
# The bracket holds unordered tokens, so +yolo and base=<branch> may appear in
# either order and either may be omitted.
#
# base = the branch a task worktree must start from. A freshly allocated pool
#   worktree lands on the repo's DEFAULT branch, which is the wrong base for a
#   project that develops elsewhere; bin/fm-spawn.sh checks this branch out and
#   refuses to launch a worker it cannot confirm is on it.
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   local-only   local branch, no remote/PR -> captain approve -> guarded local merge
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--base] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
WANT_BASE=no
if [ "${1:-}" = "--base" ]; then
  WANT_BASE=yes
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--base] <project-name>}

# A base query is advisory: an absent registry, project, or base= record all mean
# "no recorded base", and the caller falls back to the repo default branch.
if [ ! -f "$REG" ]; then
  [ "$WANT_BASE" = yes ] && exit 0
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode> <yolo> <base>" (one line, base may be empty) or nothing if
# the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; base="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo" && a[1] !~ /^base=/) mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        if (a[j] ~ /^base=/) base = substr(a[j], 6);
      }
    }
    print mode, yolo, base; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  [ "$WANT_BASE" = yes ] && exit 0
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

read -r mode yolo base <<EOF
$parsed
EOF

if [ "$WANT_BASE" = yes ]; then
  # A bracket token of "base=" alone records nothing usable; treat it as absent.
  [ -n "${base:-}" ] && echo "$base"
  exit 0
fi
case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
echo "$mode $yolo"
