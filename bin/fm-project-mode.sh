#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (exclude local-only clones from
# remote-gone branch pruning), bin/fm-home-seed.sh and bin/fm-remote-home-seed.sh
# (refuse local-only seeding and run no-mistakes init), and bin/fm-spawn.sh's
# advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so pruning, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
# --strict exits nonzero instead of falling back when the registry, project, or
# matching registry row is unresolved, ambiguous, or malformed.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--raw] [--strict] [--] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
STRICT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --raw) RAW=1; shift ;;
    --strict) STRICT=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
NAME=${1:?usage: fm-project-mode.sh [--raw] [--strict] [--] <project-name>}

if [ ! -f "$REG" ]; then
  if [ "$STRICT" -eq 1 ]; then
    echo "warn: no registry at $REG; cannot resolve $NAME" >&2
    exit 1
  fi
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<validity> <mode> <yolo>" or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  function complete_tail(delimiter) {
    return $(delimiter) == "-" && NF >= delimiter + 3 && $(NF - 1) == "(added" &&
      $NF ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/
  }
  function supported_mode(candidate) {
    return candidate == "no-mistakes" || candidate == "direct-PR" ||
      candidate == "local-only" || candidate == "no-mistakes-prod-only"
  }
  $1=="-" && $2==n {
    matches++;
    if (matches > 1) next;
    mode="no-mistakes"; yolo="off";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo") mode = a[1];
      for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
    }
    valid=0;
    if ($3 == "-") valid=complete_tail(3);
    else if ($3 ~ /^\[[^][]+\]$/) {
      explicit_mode=substr($3, 2, length($3) - 2);
      valid=supported_mode(explicit_mode) && complete_tail(4);
    } else if ($3 ~ /^\[[^][]+$/ && $4 == "+yolo]") {
      explicit_mode=substr($3, 2);
      valid=supported_mode(explicit_mode) && complete_tail(5);
    }
  }
  END {
    if (matches > 0) print (matches == 1 && valid ? "valid" : "malformed"), mode, yolo;
  }
' "$REG")

if [ -z "$parsed" ]; then
  if [ "$STRICT" -eq 1 ]; then
    echo "warn: project \"$NAME\" not in registry; cannot resolve mode" >&2
    exit 1
  fi
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

parse_status=${parsed%% *}
parsed=${parsed#* }
if [ "$STRICT" -eq 1 ] && [ "$parse_status" != "valid" ]; then
  echo "warn: malformed or duplicate registry row for \"$NAME\"; cannot resolve mode" >&2
  exit 1
fi

mode=${parsed%% *}
yolo=${parsed##* }
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *)
    if [ "$STRICT" -eq 1 ]; then
      echo "warn: unknown mode \"$mode\" for $NAME; cannot resolve mode" >&2
      exit 1
    fi
    echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2
    mode=no-mistakes
    yolo=off
    ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
