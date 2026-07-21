#!/usr/bin/env bash
# Resolve a project's delivery mode and yolo flag from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> direct-PR off  (standard default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# mode = how a finished change reaches main:
#   no-mistakes  explicit opt-in: full pipeline -> PR -> captain merge
#   direct-PR    standard: project tests -> push + PR via gh-axi -> captain merge
#   local-only   local branch, no remote/PR -> captain approve -> guarded local merge
# yolo (orthogonal) = when on, firstmate makes approval decisions itself (PR merges,
#   ask-user findings, local-only merge approval) without checking the captain - except
#   anything destructive/irreversible/security-sensitive, which still escalates.
#
# An optional task id applies the explicit task override recorded at
# data/<task-id>/delivery-mode by fm-brief.sh --mode. The override changes only
# delivery mode; the project's +yolo posture remains orthogonal.
#
# A missing registry, unregistered project, or unannotated legacy line resolves
# to "direct-PR off". An unknown explicit mode or malformed task override fails
# closed instead of silently selecting the faster path, preserving the original
# safety reason for the old no-mistakes fallback.
# Usage: fm-project-mode.sh <project-name> [--task <task-id>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
NAME=${1:?usage: fm-project-mode.sh <project-name> [--task <task-id>]}
shift
TASK_ID=
case "${1:-}" in
  '') ;;
  --task)
    [ "$#" -eq 2 ] || { echo "error: --task requires exactly one task id" >&2; exit 2; }
    TASK_ID=$2
    ;;
  *) echo "error: usage: fm-project-mode.sh <project-name> [--task <task-id>]" >&2; exit 2 ;;
esac

DEFAULT_MODE=direct-PR
TASK_MODE=
if [ -n "$TASK_ID" ]; then
  case "$TASK_ID" in
    *[!A-Za-z0-9._-]*|'') echo "error: invalid task id '$TASK_ID'" >&2; exit 2 ;;
  esac
  TASK_MODE_FILE="$DATA/$TASK_ID/delivery-mode"
  if [ -e "$TASK_MODE_FILE" ] || [ -L "$TASK_MODE_FILE" ]; then
    [ -f "$TASK_MODE_FILE" ] && [ ! -L "$TASK_MODE_FILE" ] \
      || { echo "error: unsafe task delivery-mode override at $TASK_MODE_FILE" >&2; exit 2; }
    TASK_MODE=$(sed -n '1p' "$TASK_MODE_FILE")
    [ "$(wc -l < "$TASK_MODE_FILE" | tr -d '[:space:]')" = 1 ] \
      || { echo "error: task delivery-mode override must contain exactly one line at $TASK_MODE_FILE" >&2; exit 2; }
    case "$TASK_MODE" in
      no-mistakes|direct-PR|local-only) ;;
      *) echo "error: unknown task delivery mode '$TASK_MODE' at $TASK_MODE_FILE" >&2; exit 2 ;;
    esac
  fi
fi

mode=$DEFAULT_MODE
yolo=off
if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to $DEFAULT_MODE off" >&2
else
  # awk emits "<mode> <yolo>" (one line) or nothing if the project is absent.
  parsed=$(awk -v n="$NAME" -v default_mode="$DEFAULT_MODE" '
    $1=="-" && $2==n {
      mode=default_mode; yolo="off";
      if ($3 ~ /^\[/) {
        s="";
        for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
        k = split(s, a, " ");
        if (a[1] != "" && a[1] != "+yolo") mode = a[1];
        for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
      }
      print mode, yolo; exit
    }
  ' "$REG")
  if [ -z "$parsed" ]; then
    echo "warn: project \"$NAME\" not in registry; defaulting to $DEFAULT_MODE off" >&2
  else
    mode=${parsed%% *}
    yolo=${parsed##* }
    case "$mode" in
      no-mistakes|direct-PR|local-only) ;;
      *) echo "error: unknown explicit mode \"$mode\" for $NAME" >&2; exit 2 ;;
    esac
  fi
fi
case "$yolo" in on|off) ;; *) yolo=off ;; esac
[ -z "$TASK_MODE" ] || mode=$TASK_MODE
echo "$mode $yolo"
