#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture or external-contract setting
# from the data/projects.md registry.
# The default form prints two words to stdout: "<mode> <yolo>" where mode is one
# of no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [<mode> +external-contract] - <desc> ...  -> external contract on
#   - <name> [+external-contract] - <desc> (added <date>) -> external contract on
# A leading + marks a flag, never a mode, so a mode-less annotation carrying only
# flags keeps the legacy no-mistakes default instead of warning about a bogus mode.
#
# +external-contract is an independent, opt-in per-project setting. Its complete
# private contract lives at data/project-contracts/<name>.md. The switch belongs
# in this registry because it is project posture; the content belongs in data/
# because it is durable Firstmate-private knowledge, not a local config choice.
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
# --external-contract prints data/project-contracts/<name>.md only when the exact
# registry row carries +external-contract; otherwise it prints nothing. It never
# infers the setting from file presence, so a missing contract remains detectable.
# The marker is read from the row's annotation only - the fields between the name
# and the " - " that opens the free-text description - and is matched with any
# surrounding bracket punctuation stripped, so a description that merely mentions
# the marker never marks a project and a bracket spelling never hides one.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr in delivery-posture mode, so a typo never silently drops the gate.
# An unrecognized +token in the annotation is REFUSED for every form of this
# command instead, because an unread flag fails open rather than onto the most
# rigorous posture: the diagnostic names the token and the valid set.
# Usage: fm-project-mode.sh [--raw|--external-contract] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
EXTERNAL_CONTRACT=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --external-contract) EXTERNAL_CONTRACT=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw|--external-contract] <project-name>}

# Every +token this registry grammar defines. A row is refused rather than read
# when its annotation carries anything else, because every unrecognized flag
# fails OPEN: a mistyped +external-contract leaves the project looking ordinary,
# so bin/fm-brief.sh emits a brief with no contract snapshot and no publication
# prohibition and bin/fm-ensure-agents-md.sh lets agent files be created in that
# project's git - the exact outcome the setting exists to prevent. An unknown
# MODE keeps its long-standing warn-and-default-to-no-mistakes behavior below,
# because that direction fails closed onto the most rigorous posture.
KNOWN_FLAGS="+yolo +external-contract"
if [ -f "$REG" ]; then
  unknown_flags=$(awk -v n="$NAME" -v valid="$KNOWN_FLAGS" '
    BEGIN { k = split(valid, v, " "); for (i = 1; i <= k; i++) known[v[i]] = 1 }
    $1=="-" && $2==n {
      if ($3 ~ /^\[/) {
        s="";
        for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s);
        k2 = split(s, a, " ");
        for (j=1; j<=k2; j++) if (a[j] ~ /^\+/ && !(a[j] in known)) print a[j]
      }
      exit
    }
  ' "$REG") || {
    echo "error: cannot read project registry at $REG" >&2
    exit 1
  }
  if [ -n "$unknown_flags" ]; then
    printf 'error: project %s has an unrecognized registry flag: %s; valid flags are %s\n' \
      "$NAME" "$(printf '%s' "$unknown_flags" | tr '\n' ' ' | sed 's/ $//')" "$KNOWN_FLAGS" >&2
    exit 1
  fi
fi

if [ "$EXTERNAL_CONTRACT" -eq 1 ]; then
  [ -f "$REG" ] || exit 0
  marked=$(awk -v n="$NAME" '
    $1=="-" && $2==n {
      for (i=3; i<=NF; i++) {
        if ($i=="-") break
        t=$i; gsub(/[][]/, "", t)
        if (t=="+external-contract") { print "on"; break }
      }
      exit
    }
  ' "$REG") || {
    echo "error: cannot read project registry at $REG" >&2
    exit 1
  }
  if [ "$marked" = on ]; then
    printf '%s/project-contracts/%s.md\n' "$DATA" "$NAME"
  fi
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
      if (a[1] != "" && a[1] !~ /^\+/) mode = a[1];
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
