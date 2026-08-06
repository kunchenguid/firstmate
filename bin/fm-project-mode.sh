#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only|gate-merge and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice and its gate-merge
# authorization check.
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
#   gate-merge             the crewmate lands its own work by running the project's
#                          own merge gate; no PR and no firstmate merge. Registering
#                          it is the captain's standing authorization for that gate,
#                          and the entry's note records the exact gate command as
#                          gate=`<command>` so every task lands the same way.
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# --gate is a separate accessor, not a widening of the two-word line above, so the
# mechanical consumers keep reading exactly two words. It prints the gate command
# recorded in the matched entry's note, taken from the first gate=`<command>` on that
# line and empty when the entry records none, and it exits non-zero when the registered
# posture could not be read at all: no registry file, no entry for the project, or an
# entry whose mode annotation is not a recognized mode. bin/fm-spawn.sh uses that exit
# status to tell an unambiguous registry conflict, which refuses a gate-merge spawn,
# from a posture it simply could not verify, which only warns.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--raw|--gate] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
GATE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --raw) RAW=1; shift ;;
    --gate) GATE_ONLY=1; shift ;;
    *) break ;;
  esac
done
NAME=${1:?usage: fm-project-mode.sh [--raw|--gate] <project-name>}

if [ ! -f "$REG" ]; then
  if [ "$GATE_ONLY" -eq 1 ]; then
    echo "warn: no registry at $REG; no registered posture to read for $NAME" >&2
    exit 3
  fi
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode>\t<yolo>\t<gate>" (one line) or nothing if the project is absent.
# The tab separator keeps a gate command's own spaces intact.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; gate="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo") mode = a[1];
      for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
    }
    p = index($0, "gate=`");            # the note records the landing command backticked
    if (p > 0) {
      rest = substr($0, p + 6);
      q = index(rest, "`");
      if (q > 1) gate = substr(rest, 1, q - 1);
    }
    printf "%s\t%s\t%s\n", mode, yolo, gate; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  if [ "$GATE_ONLY" -eq 1 ]; then
    echo "warn: project \"$NAME\" not in registry; no registered posture to read" >&2
    exit 3
  fi
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

IFS=$'\t' read -r mode yolo gate <<EOF
$parsed
EOF
mode_known=1
case "$mode" in
  no-mistakes|direct-PR|local-only|gate-merge|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off; mode_known=0 ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac

# An entry whose mode annotation is unreadable is not a posture anyone can act on, so
# --gate reports it as unverified rather than handing back a gate under a guessed mode.
if [ "$GATE_ONLY" -eq 1 ]; then
  [ "$mode_known" -eq 1 ] || exit 3
  printf '%s\n' "$gate"
  exit 0
fi
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
