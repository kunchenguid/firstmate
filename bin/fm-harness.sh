#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: codex|pi|traex|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh validate-native-effort <harness> <model> <effort>
#                                        Refuse ultra unless the harness is pi
#                                        and the model explicitly names
#                                        codex-native/<id>. Other efforts retain
#                                        their adapter's existing policy. Native
#                                        Codex validates model support at startup.
#        fm-harness.sh ancestry [<pid>] print "<strength> <harness>" for the nearest
#                                        harness process at or above <pid> (default this
#                                        process), or nothing when the walk finds none.
#                                        Ancestry evidence only, with no marker layer, so
#                                        a real harness process can be asked what the walk
#                                        makes of it (tests/fm-harness-liveness-drift-live-e2e.test.sh).
#        fm-harness.sh ancestry-descent [<pid>] [<leaf-pid>...]
#                                        print each DISTINCT "<strength> <harness>" the walk
#                                        reaches from the vantages on the UPWARD path
#                                        between the deepest descendant of <pid> and <pid>
#                                        itself, deepest first. Same evidence-only purpose
#                                        as `ancestry`, asked from the vantage point a tool
#                                        subprocess actually occupies rather than from the
#                                        top of the session, which is the only place a
#                                        harness behind an interpreter shim can be seen at
#                                        comm strength. Optional <leaf-pid> values restrict
#                                        which descendants may be chosen as the deepest one,
#                                        so a caller that knows the terminal's foreground
#                                        process group can keep a backgrounded process out
#                                        of the selection.
# Detection evidence and precedence:
#   Markers  - verified environment variables a harness publishes about itself.
#              Cheap and unambiguous about WHICH harness set them, but they are
#              ordinary environment state: a child inherits them, and a terminal
#              multiplexer can replay a stale one into an unrelated session.
#   Ancestry - the nearest harness process in this process's parent chain. This
#              is the structural fact about who actually owns the process tree,
#              so it is what settles a disagreement.
# detect_own is the single owner of how the two combine; harness_marker and
# harness_ancestry only report evidence. Record each newly verified env marker
# in harness_marker, and each newly verified command name in harness_ancestry.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# Only maintained harnesses provide detection evidence.
harness_marker() {
  [ "${FM_TRAEX_HARNESS:-}" = traex ] && { echo traex; return; }
  [ "${PI_CODING_AGENT:-}" = true ] && { echo pi; return; }
  return 0
}

harness_process_verdict() { # <pid>
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
  case "$(basename -- "$comm")" in
    *codex*) echo "comm codex"; return ;;
    pi|pi-launcher) echo "comm pi"; return ;;
    node*|python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      case "$args" in
        *codex*) echo "args codex"; return ;;
        *" pi "*|*/pi) echo "args pi"; return ;;
      esac ;;
  esac
}

# Print the verdict for the NEAREST harness process in the parent chain, or
# nothing when the walk finds none. The nearest match wins, so a worker nested
# inside another harness resolves to its own harness.
harness_ancestry() {  # [<pid>]
  local pid=${1:-$$} verdict
  for _ in 1 2 3 4 5 6 7 8; do
    verdict=$(harness_process_verdict "$pid")
    [ -z "$verdict" ] || { echo "$verdict"; return; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Stop only once the walk has EXAMINED the top of the chain. Inside a PID
    # namespace the harness itself is pid 1 - a container, or the `codex sandbox`
    # this boundary was proven in - so breaking as soon as the next pid is 1
    # skips the one process that identifies the session and hands the verdict
    # straight back to a retained marker. A host's real pid 1 (init, systemd,
    # launchd) matches no harness name above, so examining it costs one ps call
    # and can introduce no false positive.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  return 0
}

# Print the pids on the UPWARD path between the deepest descendant of <root> and
# <root> itself, deepest first. Optional <eligible-leaf-pid> values restrict which
# descendants may be chosen as that deepest one; with none given every descendant
# is eligible. Bounded to the same eight levels harness_ancestry climbs, so a deep
# or pathological tree cannot make this walk unbounded.
process_descent_path() {  # <root> [<eligible-leaf-pid>...]
  local root=${1:-$$} eligible any hit pairs frontier next pid child parent verdict
  local parents='' depth=0 best best_depth=0 best_strength='' hops=0
  case "$root" in '' | *[!0-9]*) return 0 ;; esac
  shift 2>/dev/null || true
  eligible=" ${*+$*} "
  any=0
  [ "$#" -eq 0 ] && any=1
  pairs=$(ps -eo pid=,ppid= 2>/dev/null) || { printf '%s\n' "$root"; return 0; }
  best=$root
  frontier=$root
  while [ -n "$frontier" ] && [ "$depth" -lt 8 ]; do
    next=
    for pid in $frontier; do
      while read -r child parent; do
        [ "$parent" = "$pid" ] || continue
        [ "$child" != "$pid" ] || continue
        parents="$parents $child:$pid"
        next="$next $child"
        if [ "$any" = 1 ]; then
          hit=1
        else
          case "$eligible" in
            *" $child "*) hit=1 ;;
            *) hit=0 ;;
          esac
        fi
        if [ "$hit" = 1 ]; then
          verdict=$(harness_process_verdict "$child")
          if [ $((depth + 1)) -gt "$best_depth" ]; then
            best=$child
            best_depth=$((depth + 1))
            best_strength=${verdict%% *}
          # At equal depth, prefer the leaf whose own executable reaches comm
          # strength. Otherwise an earlier MCP interpreter carrying a foreign
          # harness path can hide a native harness sibling purely through ps
          # ordering. This repairs the chosen path's comm-strength guarantee;
          # args-strength foreign verdicts remain excluded from cross-checking.
          elif [ $((depth + 1)) -eq "$best_depth" ] \
            && [ "$best_strength" != comm ] && [ "${verdict%% *}" = comm ]; then
            best=$child
            best_strength='comm'
          fi
        fi
      done <<EOF
$pairs
EOF
    done
    frontier=$next
    depth=$((depth + 1))
  done

  pid=$best
  while [ -n "$pid" ] && [ "$hops" -le 8 ]; do
    printf '%s\n' "$pid"
    [ "$pid" != "$root" ] || break
    parent=
    case "$parents" in
      *" $pid:"*)
        parent=${parents##*" $pid:"}
        parent=${parent%% *} ;;
    esac
    pid=$parent
    hops=$((hops + 1))
  done
}

# Print each DISTINCT "<strength> <harness>" verdict harness_ancestry reaches from
# the vantages on the upward path between the deepest descendant of <root> and
# <root>, one per line, deepest first.
#
# Why a descent path and not <root> alone: detect_own always runs from a TOOL
# SUBPROCESS inside a session, never from the process at the top of it, and that
# difference decides whether a retained foreign marker can rename the session. A
# harness that ships as an interpreter shim spawning its native binary as a CHILD
# is only args strength when asked from the shim, and detect_own hands an
# args-strength verdict straight back to the marker; the native child is comm
# strength and outranks it. Asking from below is what puts the question at the
# vantage point a real session uses, so a guard built on this can assert the
# strength the shipped guarantee actually depends on
# (tests/fm-harness-liveness-drift-live-e2e.test.sh).
#
# Why the upward path and not the whole subtree: harness_ancestry only ever climbs,
# so a SIBLING branch is a vantage firstmate's own detection can never occupy. A
# harness-spawned MCP server can carry another harness name in its script path;
# sibling helper processes are not evidence from the active tool ancestry.
harness_ancestry_descent() {  # <root> [<eligible-leaf-pid>...]
  local pid verdict seen=
  for pid in $(process_descent_path "$@"); do
    verdict=$(harness_ancestry "$pid")
    [ -n "$verdict" ] || continue
    case "$seen" in *"|$verdict|"*) continue ;; esac
    seen="$seen|$verdict|"
    printf '%s\n' "$verdict"
  done
}

# Structural ancestry outranks a stale marker from a different harness.
detect_own() {
  local marker ancestry strength harness
  marker=$(harness_marker)
  ancestry=$(harness_ancestry)
  if [ -z "$ancestry" ]; then
    if [ -n "$marker" ]; then echo "$marker"; else echo unknown; fi
    return
  fi
  strength=${ancestry%% *}
  harness=${ancestry#* }
  [ -n "$marker" ] || { echo "$harness"; return; }
  if [ "$marker" = "$harness" ]; then
    echo "$marker"
    return
  fi
  if [ "$strength" = comm ]; then echo "$harness"; else echo "$marker"; fi
}

# Shared selection boundary. Historical metadata keeps its original harness;
# this check never rewrites a record or silently selects a replacement.
validate_harness() {
  case "${1:-}" in pi|codex|traex) return 0 ;; esac
  echo "error: unsupported harness '${1:-none}'; supported harnesses: pi, codex, traex. Update ${2:-the harness selection} explicitly; historical task records and work are preserved." >&2
  return 1
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else validate_harness "$crew" config/crew-harness && echo "$crew"; fi
}

validate_native_effort() {
  local harness=${1:-} model=${2:-} effort=${3:-}
  [ "$effort" = ultra ] || return 0
  case "$harness" in
    pi)
      case "$model" in codex-native/?*) return 0 ;; esac
      ;;
  esac
  echo "error: ultra effort requires pi with an explicit codex-native/<model> model" >&2
  return 1
}

case "${1:-}" in
  validate) validate_harness "${2:-}" ;;
  validate-native-effort) shift; validate_native_effort "$@" ;;
  ancestry)
    case "${2:-}" in
      ''|*[!0-9]*) [ -z "${2:-}" ] || { echo "error: ancestry takes a numeric pid" >&2; exit 2; } ;;
    esac
    harness_ancestry "${2:-$$}"
    ;;
  ancestry-descent)
    shift
    for arg in ${1+"$@"}; do
      case "$arg" in
        ''|*[!0-9]*) echo "error: ancestry-descent takes numeric pids" >&2; exit 2 ;;
      esac
    done
    descent_pid="${1:-$$}"
    [ "$#" -eq 0 ] || shift
    harness_ancestry_descent "$descent_pid" ${1+"$@"}
    ;;
  crew) resolve_crew ;;
  *) detect_own ;;
esac
