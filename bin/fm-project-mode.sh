#!/usr/bin/env bash
# Resolve a project's delivery mode and yolo flag from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> legacy, migrated to direct-PR +yolo
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (legacy explicit opt-in)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   local-only   local branch, no remote/PR -> captain approve -> guarded local merge
# yolo (orthogonal) = when on, firstmate makes approval decisions itself (PR merges,
#   ask-user findings, local-only merge approval) without checking the captain - except
#   anything destructive/irreversible/security-sensitive, which still escalates.
#
# An unknown/missing project or unknown/malformed mode falls back to "direct-PR off"
# and warns to stderr, so a typo never silently grants yolo authority or drops to an
# opaque LLM review path.
# Usage: fm-project-mode.sh <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
NAME=${1:?usage: fm-project-mode.sh <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to direct-PR off" >&2
  echo "direct-PR off"
  exit 0
fi

# awk emits "<mode> <yolo>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    if ($3 !~ /^\[/) {
      print "direct-PR", "on"; exit
    }
    mode=""; yolo="off"; s=""; closed=0;
    for (i=3; i<=NF; i++) {
      s = s (s==""?"":" ") $i
      if ($i ~ /\]$/) { closed=1; break }
    }
    if (!closed) { print "malformed", "off"; exit }
    gsub(/^\[|\]$/, "", s);
    k = split(s, a, " ");
    if (k < 1 || a[1] == "" || a[1] == "+yolo") { print "malformed", "off"; exit }
    mode=a[1]
    for (j=2; j<=k; j++) {
      if (a[j] == "+yolo") yolo="on"
      else { print "malformed", "off"; exit }
    }
    print mode, yolo; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to direct-PR off" >&2
  echo "direct-PR off"
  exit 0
fi

mode=${parsed%% *}
yolo=${parsed##* }
case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to direct-PR off" >&2; mode=direct-PR; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) echo "warn: malformed yolo flag for $NAME; defaulting to off" >&2; yolo=off ;; esac
echo "$mode $yolo"
