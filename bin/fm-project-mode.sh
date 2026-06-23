#!/usr/bin/env bash
# Resolve a project's delivery mode and yolo flag from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [codespace owner/repo] - <desc> (...)     -> codespace off, slug owner/repo
#
# With --slug, prints the codespace owner/repo slug from the bracket (the token
# containing a "/") and nothing else, exiting non-zero if there is none. This lets
# codespace projects register with NO local clone: owner/repo comes from the
# registry, not from a clone's origin remote. Usage: fm-project-mode.sh --slug <name>
#
# With --codespace-harness, prints the agent harness a codespace crewmate should
# run, taken from the bracket's optional harness token (any token that is neither
# "codespace", the owner/repo slug, nor "+yolo"); defaults to "claude" when the
# bracket names no harness. The codespace crewmate runs over SSH inside the
# codespace, so the named harness must already be installed there. Bracket form:
#   [codespace <owner/repo> [<harness>] [+yolo]]   e.g. [codespace acme/widget cursor]
# Usage: fm-project-mode.sh --codespace-harness <name>
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   local-only   local branch, no remote/PR -> firstmate review -> captain approve -> local merge
#   codespace    crewmate SSH-es into the project's GitHub Codespace; no local worktree
# yolo (orthogonal) = when on, firstmate makes approval decisions itself (PR merges,
#   ask-user findings, local-only merge approval) without checking the captain - except
#   anything destructive/irreversible/security-sensitive, which still escalates.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"

SLUG_MODE=
CS_HARNESS_MODE=
if [ "${1:-}" = "--slug" ]; then
  SLUG_MODE=1
  shift
elif [ "${1:-}" = "--codespace-harness" ]; then
  CS_HARNESS_MODE=1
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--slug|--codespace-harness] <project-name>}

if [ -n "$CS_HARNESS_MODE" ]; then
  # Print the codespace harness token from the [codespace ...] bracket, or
  # "claude" when none is named. The harness is any bracket token that is not
  # "codespace", the owner/repo slug (contains "/"), or "+yolo".
  harness=claude
  if [ -f "$REG" ]; then
    h=$(awk -v n="$NAME" '
      $1=="-" && $2==n {
        if ($3 ~ /^\[/) {
          s="";
          for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
          gsub(/^\[|\]$/, "", s);
          k = split(s, a, " ");
          for (j=1; j<=k; j++) {
            if (a[j]=="codespace" || a[j]=="+yolo" || a[j]=="") continue;
            if (a[j] ~ /\//) continue;   # owner/repo slug
            print a[j]; exit;
          }
        }
        exit
      }
    ' "$REG")
    [ -n "$h" ] && harness=$h
  fi
  printf '%s\n' "$harness"
  exit 0
fi

if [ -n "$SLUG_MODE" ]; then
  # Print the owner/repo slug from the project's [codespace owner/repo] bracket.
  [ -f "$REG" ] || exit 1
  slug=$(awk -v n="$NAME" '
    $1=="-" && $2==n {
      if ($3 ~ /^\[/) {
        s="";
        for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s);
        k = split(s, a, " ");
        for (j=1; j<=k; j++) if (a[j] ~ /\//) { print a[j]; exit }
      }
      exit
    }
  ' "$REG")
  [ -n "$slug" ] || exit 1
  printf '%s\n' "$slug"
  exit 0
fi

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode> <yolo>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off";
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
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

mode=${parsed%% *}
yolo=${parsed##* }
case "$mode" in
  no-mistakes|direct-PR|local-only|codespace) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
echo "$mode $yolo"
