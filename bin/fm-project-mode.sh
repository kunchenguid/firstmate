#!/usr/bin/env bash
# Resolve a project's delivery mode, yolo flag, and optional base ref from the
# data/projects.md registry.
# By default, prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# With --base, prints only the optional base ref, or nothing when unset.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [<mode> base=origin/dev] - <desc> (...)    -> mode + base ref
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   local-only   local branch, no remote/PR -> firstmate review -> captain approve -> local merge
# yolo (orthogonal) = when on, firstmate makes approval decisions itself (PR merges,
#   ask-user findings, local-only merge approval) without checking the captain - except
#   anything destructive/irreversible/security-sensitive, which still escalates.
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
FIELD=mode
case "${1:-}" in
  --base) FIELD=base; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--base] <project-name>}

if [ ! -f "$REG" ]; then
  [ "$FIELD" = base ] && exit 0
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode> <yolo>\t<base>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; base="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo") mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        if (a[j] ~ /^base=/) base=substr(a[j], 6);
      }
    }
    print mode " " yolo "\t" base; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  [ "$FIELD" = base ] && exit 0
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

mode_yolo=${parsed%%$'\t'*}
base=${parsed#*$'\t'}
mode=${mode_yolo%% *}
yolo=${mode_yolo##* }
case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
case "$base" in
  *[!A-Za-z0-9._/@:+-]*) echo "warn: invalid base \"$base\" for $NAME; ignoring" >&2; base= ;;
esac
if [ "$FIELD" = base ]; then
  [ -z "$base" ] || echo "$base"
else
  echo "$mode $yolo"
fi
