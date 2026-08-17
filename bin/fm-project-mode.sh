#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture and autonomy grants from the
# data/projects.md registry.
# Prints two words to stdout: "<mode> <grants>" where mode is one of
# no-mistakes|direct-PR|local-only and grants is a canonically ordered comma list
# of the granted names, or "none".
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
#   - <name> - <desc> (added <date>)                    -> no-mistakes none  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)            -> <mode> none
#   - <name> [<mode> +yolo] - <desc> (added <date>)      -> <mode> findings,merge,local-merge
#   - <name> [<mode> +yolo:<g>[,<g>]] - <desc> (added ..)-> <mode> <those grants only>
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
#
# grants (orthogonal to mode) = which routine approvals firstmate may make itself,
# without checking the captain. They are INDEPENDENT: holding one never implies another.
#   findings      answer no-mistakes ask-user/review findings
#   merge         merge a green PR
#   local-merge   approve a local-only branch for the guarded local merge
# Bare `+yolo` is shorthand for all three, so every registry line written before
# grants were split keeps exactly the meaning it had. Repeat the flag
# (`+yolo:merge +yolo:findings`) or use a comma list (`+yolo:merge,findings`).
#
# No grant ever covers destructive, irreversible, or security-sensitive decisions,
# and `merge` never covers a red PR; both always escalate to the captain.
# AGENTS.md section 7 is the single owner of authority exceptions, including
# ask-user contract expansion and stronger captain boundaries.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# Everything unrecognised resolves to the LEAST permission and warns to stderr: a
# missing registry, an absent project, an unknown mode, and an unknown grant name
# all grant nothing, so a typo can never widen authority.
#
# Usage: fm-project-mode.sh [--raw] <project-name>
#        fm-project-mode.sh [--raw] <project-name> --grant <findings|merge|local-merge>
#
# --grant is the interface for asking a permission question: it prints nothing and
# exits 0 when the grant is held, 1 when it is not, and 2 on a usage error or an
# unknown grant name. Both non-zero exits mean "not granted", so `if ... ; then`
# denies by default on any mistake.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
NAME=
QUERY=
# Whether --grant was supplied at all, tracked apart from its value: an empty
# grant name is a caller mistake and must be refused, not read as "no query".
QUERY_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --raw)
      RAW=1
      shift
      ;;
    --grant)
      [ $# -ge 2 ] || { echo "usage: fm-project-mode.sh [--raw] <project-name> [--grant <name>]" >&2; exit 2; }
      QUERY=$2
      QUERY_SET=1
      shift 2
      ;;
    -*) echo "error: unknown option \"$1\"" >&2; exit 2 ;;
    *)
      [ -z "$NAME" ] || { echo "error: unexpected argument \"$1\"" >&2; exit 2; }
      NAME=$1
      shift
      ;;
  esac
done
[ -n "$NAME" ] || { echo "usage: fm-project-mode.sh [--raw] <project-name> [--grant <name>]" >&2; exit 2; }

# An unknown grant name is a caller mistake, not a denial: refuse it loudly with
# its own exit code so it can never be mistaken for a resolved "not granted".
if [ "$QUERY_SET" = 1 ]; then
  case "$QUERY" in
    findings|merge|local-merge) ;;
    *) echo "error: unknown grant \"$QUERY\"; expected findings, merge, or local-merge" >&2; exit 2 ;;
  esac
fi

G_FINDINGS=off
G_MERGE=off
G_LOCAL_MERGE=off

# grant_apply <name> -> enables one grant, or returns 1 if the name is not one.
grant_apply() {
  case "$1" in
    findings) G_FINDINGS=on ;;
    merge) G_MERGE=on ;;
    local-merge) G_LOCAL_MERGE=on ;;
    *) return 1 ;;
  esac
}

# emit <mode> -> prints the resolved line, or answers a --grant query.
emit() {
  local mode=$1 grants=""
  # A conditional policy is not a task mode. Mechanical callers get its most
  # rigorous leg; --raw callers get the annotation itself (see the header).
  if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
    mode=no-mistakes
  fi
  if [ "$G_FINDINGS" = on ]; then grants="findings"; fi
  if [ "$G_MERGE" = on ]; then grants="${grants:+$grants,}merge"; fi
  if [ "$G_LOCAL_MERGE" = on ]; then grants="${grants:+$grants,}local-merge"; fi
  [ -n "$grants" ] || grants=none

  # Answer the query from the canonical list built above rather than from a
  # second enumeration of the grant names, so a name that is not in that list is
  # structurally denied instead of relying on the caller-side validation alone.
  if [ "$QUERY_SET" = 1 ]; then
    case ",$grants," in
      *",$QUERY,"*) exit 0 ;;
      *) exit 1 ;;
    esac
  fi
  echo "$mode $grants"
  exit 0
}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes with no grants" >&2
  emit no-mistakes
fi

# awk emits "<mode><TAB><flag tokens>" (one line) or nothing if the project is absent.
# Only the first bracket word can name the mode; every "+" word is a flag token.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; toks="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      for (j=1; j<=k; j++) {
        if (a[j] == "") continue;
        if (substr(a[j], 1, 1) == "+") { toks = toks (toks==""?"":" ") a[j]; continue }
        if (j == 1) mode = a[j];
      }
    }
    printf "%s\t%s\n", mode, toks; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes with no grants" >&2
  emit no-mistakes
fi

mode=${parsed%%	*}
toks=${parsed#*	}
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *)
    echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes with no grants" >&2
    emit no-mistakes
    ;;
esac

# Walk the flag tokens. An unrecognised token or grant name is dropped with a
# warning: it never widens permission, and it never voids a valid sibling.
# Word splitting is wanted here; globbing is not, or a malformed flag holding a
# "*" would expand against the working directory instead of being reported.
set -f
for tok in $toks; do
  case "$tok" in
    +yolo)
      grant_apply findings
      grant_apply merge
      grant_apply local-merge
      ;;
    +yolo:*)
      rest=${tok#+yolo:}
      if [ -z "$rest" ]; then
        echo "warn: empty grant list in \"$tok\" for $NAME; granting nothing from it" >&2
        continue
      fi
      while [ -n "$rest" ]; do
        one=${rest%%,*}
        if [ "$one" = "$rest" ]; then rest=""; else rest=${rest#*,}; fi
        if [ -z "$one" ]; then continue; fi
        grant_apply "$one" || echo "warn: unknown autonomy grant \"$one\" for $NAME; granting nothing from it" >&2
      done
      ;;
    *)
      echo "warn: unknown registry flag \"$tok\" for $NAME; granting nothing from it" >&2
      ;;
  esac
done
set +f

emit "$mode"
