#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints three words to stdout: "<mode> <yolo> <forge>" where mode is one of
# no-mistakes|direct-PR|local-only, yolo is on|off, and forge is none|gerrit.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh and bin/fm-remote-home-seed.sh (refuse local-only seeding,
# run no-mistakes init), bin/fm-spawn.sh's advisory registry-deviation notice plus
# its forge agreement and yolo refusal, and bin/fm-promote.sh, which takes the
# forge binding from here because it is a project fact rather than a task choice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off none  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off none
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on none
#   - <name> [<mode> forge=gerrit] - <desc> (added <date>) -> <mode> off gerrit
# `+yolo` and `forge=` are order-independent annotation tokens that may appear
# together; only the FIRST token is read as the mode. They are the ONLY tokens an
# annotation may carry beside that mode: anything else is refused rather than
# ignored, because a silently dropped `forg=gerrit` binds no forge at all.
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
# forge (orthogonal, and orthogonal to yolo too) = which forge the project's
#   remote actually is, never inferred from mode, remote name, host, or protocol.
#   `none` means a forge whose pull requests and checks no-mistakes already
#   drives, and `gerrit` means a Gerrit server: no pull requests, so the worker
#   publishes a change with gerrit-axi instead (bin/fm-dod-lib.sh owns what that
#   changes for a worker in each publishing mode).
#   The binding is EXPLICIT because a provider family must never be guessed;
#   bin/fm-forge-detect.sh proposes it from a protocol fact at project-add
#   intake, and the captain's confirmation is what this record holds.
#   A forge describes what a mode publishes, so it composes with no-mistakes and
#   direct-PR and is REFUSED on local-only, which publishes nothing: that mode
#   lands by fast-forwarding local main, which on a review-server project
#   advances it with content the server has never seen
#   (docs/gerrit-forge-integration.md section 3).
#
# A registered `forge=gerrit` project reports yolo=off with an explicit stderr
# refusal, on the captain's decision of 2026-09-15: a Gerrit Code-Review+2 is a
# positive attributed claim that a named human approved, read by colleagues and
# by any audit, and firstmate must not manufacture one.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
# It affects the mode field only.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off none" and
# warns to stderr, so a typo never silently drops the gate. An unrecognized
# annotation token is REFUSED instead - both a `forge=` value outside the closed
# set and a token the parser does not know at all, such as `forg=gerrit` or a bare
# `gerrit`: nothing is printed to stdout and the exit status is 3, naming the bad
# token and the accepted set. A mistyped forge resolved to "no registered forge"
# would hand a Gerrit project the pull-request contract this binding exists to
# prevent, so it fails closed rather than degrading. An absent or empty `forge=`
# value is not a typo and still means no registered forge, and an annotation with
# no tokens at all keeps the legacy default. A local-only mode carrying a forge
# is refused the same way, with the same exit status.
# Usage: fm-project-mode.sh [--raw] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--raw] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off none" >&2
  echo "no-mistakes off none"
  exit 0
fi

# awk emits "posture <mode> <yolo> <forge>", "token <bad-token>" for an annotation
# token it does not recognize, "unterminated" for a bracket the line never closes,
# or nothing if the project is absent. A `forge=` token with an empty value reaches
# the shell as an empty forge field, which the closed-set check below reads as no
# registered forge, exactly like an annotation carrying no forge token at all.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; forge="none";
    if ($3 ~ /^\[/) {
      s=""; closed=0;
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) { closed=1; break } }
      if (!closed) { print "unterminated"; exit }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") { yolo="on"; continue }
        if (a[j] ~ /^forge=/) { forge = substr(a[j], 7); continue }
        if (j==1) { if (a[j] != "") mode = a[j]; continue }
        print "token", a[j]; exit
      }
    }
    print "posture", mode, yolo, forge; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off none" >&2
  echo "no-mistakes off none"
  exit 0
fi

read -r kind parsed_one parsed_two parsed_three <<EOF
$parsed
EOF
if [ "$kind" = unterminated ]; then
  echo "refused: unterminated annotation for $NAME in $REG: the bracket opens but no \"]\" closes it, so the description cannot be told apart from the annotation; close the bracket after the delivery mode and any +yolo or forge= token" >&2
  exit 3
fi
if [ "$kind" = token ]; then
  echo "refused: unrecognized annotation token \"$parsed_one\" registered for $NAME in $REG; an annotation carries a delivery mode first, then only +yolo and forge=gerrit in any order; correct the registry entry" >&2
  exit 3
fi
mode=$parsed_one
yolo=$parsed_two
forge=$parsed_three
# One owner of the forge values this fleet knows. The forge field is checked
# against it, and so is the mode slot, where a forge value is a binding written
# without its token rather than a delivery mode.
KNOWN_FORGES="none gerrit"
forge_is_known() {  # <value>
  case " $KNOWN_FORGES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}
if forge_is_known "$mode"; then
  if [ "$mode" = none ]; then
    remedy="\"none\" is not a registry spelling at all, so drop the token and leave the delivery mode alone"
  else
    remedy="a forge binds only through its own token, so write \"forge=$mode\" beside the delivery mode"
  fi
  echo "refused: \"$mode\" is a forge rather than a delivery mode, and it stands in the mode slot of the annotation registered for $NAME in $REG; $remedy; correct the registry entry" >&2
  exit 3
fi
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A forge this fleet does not know is a registry error, not a posture: resolving
# it to "no registered forge" is how a Gerrit project would quietly receive the
# pull-request contract, so nothing is reported and the caller is refused.
[ -n "$forge" ] || forge=none
if ! forge_is_known "$forge"; then
  echo "refused: unknown forge \"$forge\" registered for $NAME in $REG; the accepted values are forge=gerrit, or no forge token at all for a forge whose pull requests no-mistakes already drives; correct the registry entry" >&2
  exit 3
fi
if [ "$forge" != none ] && [ "$mode" = local-only ]; then
  echo "refused: $NAME is registered local-only with forge=$forge in $REG; local-only publishes nothing, so a forge has no meaning there, and its landing would fast-forward local main with content the review server has never seen; register no-mistakes or direct-PR to publish through the forge, or drop the forge token to keep the project local" >&2
  exit 3
fi
if [ "$forge" = gerrit ] && [ "$yolo" = on ]; then
  echo "refused: +yolo is registered for $NAME but yolo is inactive for forge=gerrit, so this reports yolo=off: a Gerrit Code-Review+2 is a positive attributed claim that a named human approved, and firstmate must not manufacture one (captain's decision 2026-09-15)" >&2
  yolo=off
fi
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo $forge"
