#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones, and via the
# --unsynced query below, skip +unsynced clones with zero output),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [<mode> +unsynced] - <desc> (added <date>)  -> <mode>, fleet-sync never touches the clone
#
# +yolo and +unsynced are independent optional flag tokens and may appear
# together in either order after the mode, e.g. "[direct-PR +yolo +unsynced]".
#
# +unsynced marks a clone the captain edits and pulls outside firstmate by
# design: fleet sync (bin/fm-fleet-sync.sh) skips it exactly like a
# local-only/no-origin clone, with no fetch, drift check, or report of any
# kind, at every call site (whole-fleet sweep and single-project form alike).
# Query it with `--unsynced <project-name>`, which prints "yes" or "no" and
# nothing else; it does not participate in the "<mode> <yolo>" output below.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--raw] <project-name>
#        fm-project-mode.sh --unsynced <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
UNSYNCED_QUERY=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --unsynced) UNSYNCED_QUERY=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw|--unsynced] <project-name>}

if [ ! -f "$REG" ]; then
  if [ "$UNSYNCED_QUERY" -eq 1 ]; then
    echo "no"
    exit 0
  fi
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode> <yolo> <unsynced>" (one line) or nothing if the project is
# absent. <mode> and <yolo> keep the exact two-word contract every mechanical
# caller of the plain/--raw form already relies on; <unsynced> is a third word
# consumed only by the --unsynced query path below.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; unsynced="no";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo" && a[1] != "+unsynced") mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        if (a[j]=="+unsynced") unsynced="yes";
      }
    }
    print mode, yolo, unsynced; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  if [ "$UNSYNCED_QUERY" -eq 1 ]; then
    echo "no"
    exit 0
  fi
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

read -r mode yolo unsynced <<EOF
$parsed
EOF

if [ "$UNSYNCED_QUERY" -eq 1 ]; then
  case "$unsynced" in yes) echo yes ;; *) echo no ;; esac
  exit 0
fi

case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
