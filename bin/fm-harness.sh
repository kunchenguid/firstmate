#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate       print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        secondmate-harness behaves exactly as the crew
#                                        harness did before this knob existed.
#        fm-harness.sh secondmate-model    print the optional MODEL token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh secondmate-effort   print the optional EFFORT token from
#                                        config/secondmate-harness, or empty when absent.
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
# config/secondmate-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. A bare "<harness>" (today's format) behaves exactly as before:
# harness only, no model/effort. Only the first non-empty, non-comment line is parsed.
# Model/effort come ONLY from this file - config/crew-harness stays a bare adapter
# name and is never parsed for a model.
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

# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"

# Print the harness named by a verified environment marker, or nothing when no
# marker is present. Markers only report what the environment CLAIMS; detect_own
# decides whether that claim survives contradicting ancestry.
harness_marker() {
  # Cursor is tested BEFORE claude, deliberately. cursor-agent does NOT clear an
  # inherited CLAUDECODE, so a cursor session started by hand from a claude
  # primary carries BOTH markers and whichever is tested first wins. This
  # ordering only settles the case where ancestry finds nothing to arbitrate
  # with; a nearer claude ancestor still outranks both in detect_own.
  # Verified live on cursor-agent 2026.08.11-e8db854: CURSOR_INVOKED_AS=cursor-agent
  # is set on the agent process itself, and CURSOR_AGENT=1 is set for the
  # child/tool processes this script runs as.
  [ "${CURSOR_AGENT:-}" = "1" ] && { echo cursor; return; }
  [ "${CURSOR_INVOKED_AS:-}" = "cursor-agent" ] && { echo cursor; return; }
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  # grok set GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so the marker
  # is unambiguous WHEN PRESENT - but it is not guaranteed present. A grok 1.0.0
  # hook process carries GROK_HOOK_EVENT, GROK_HOOK_NAME, GROK_SESSION_ID, and
  # GROK_WORKSPACE_ROOT with no GROK_AGENT at all (verified from the live process
  # environment of a wedged grok 1.0.0 Stop hook, 2026-08-07). Treat this marker as
  # a fast path only; the ancestry walk below is what actually guarantees grok is
  # identified, and any rule that must be RELIABLE under grok has to test the hook
  # markers too (see .claude/settings.json Stop entries, docs/turnend-guard.md).
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # codex, opencode, kimi, and muse publish no harness-identity marker at all, so
  # they are never named here and are identified by ancestry alone. That is the
  # whole reason a foreign marker must not outrank ancestry: with markers winning
  # unconditionally, any retained CLAUDECODE would silently rename one of them.
  # muse's only documented child variable is MUSE_CURRENT_SESSION_LOG, a
  # per-session log PATH rather than an identity, and its export to tool
  # subprocesses is unverified (verified: muse 0.1.0-R708.1). Do NOT promote it
  # to a marker without verifying it reaches children AND that it cannot survive
  # in a multiplexer's stored environment.
  return 0
}

# Print "<strength> <harness>" when one process identifies a harness, or nothing.
# Strength records how the match was made:
#   comm - the ancestor's own executable name identifies the harness. This is a
#          structural fact about the running program, so it outranks a marker.
#   args - a bare interpreter matched only because a harness name appears in the
#          script path it was handed. This is the weakest inference in this file
#          (any node process holding a harness-shaped path matches it), so it is
#          used only when no marker is present.
harness_process_verdict() {  # <pid>
  local pid=$1 comm args argv0
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
  argv0=$(fm_cursor_argv0_for_pid "$pid" "$comm" 2>/dev/null || true)
  if fm_cursor_process_matches "$comm" '' "$argv0"; then
    echo "comm cursor"
    return
  fi
  case "$(basename -- "$comm")" in
    *claude*) echo "comm claude"; return ;;
    *codex*) echo "comm codex"; return ;;
    *opencode*) echo "comm opencode"; return ;;
    *grok*) echo "comm grok"; return ;;
    kimi) echo "comm kimi"; return ;;
      # muse's installed launcher ~/.local/bin/muse execs ~/.local/bin/muse-bin-<version>
      # (verified in the published launcher, muse 0.1.0-R708.1), so the live process
      # name carries the version and CHANGES on every auto-update. Match the stable
      # prefix rather than any exact name. Deliberately anchored, never *muse*, so
      # unrelated commands (musescore, amuse) cannot be misread as this harness.
      muse|muse-bin-*) echo "comm muse"; return ;;
      # Both Pi identities share this launcher name. Ancestry can only prove the
      # FAMILY; only the launch-boundary marker selects the signed identity, which
      # is why detect_own keeps a marker that agrees on the family.
      pi-signed) echo "comm pi"; return ;;
      pi) echo "comm pi"; return ;;
    node*|python*)
      # Bare interpreter: match the harness name in its script path.
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      case "$args" in
        *claude*) echo "args claude"; return ;;
        *codex*) echo "args codex"; return ;;
        *opencode*) echo "args opencode"; return ;;
        *grok*) echo "args grok"; return ;;
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
# harness-spawned MCP server running as `node <home>/.claude/mcp/<server>.js` matches
# *claude* on its script path in the bare-interpreter branch above and would report a
# foreign harness from a process no real tool subprocess ever asks from.
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

# Collapse a verdict to the harness FAMILY its evidence can actually prove, so a
# marker's more specific verdict and ancestry's coarser one are not read as a
# disagreement. Only Pi has two identities behind one launcher name.
harness_family() {
  case "$1" in
    pi-signed) printf 'pi\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Combine the two evidence layers. The precedence boundary, in one rule: a
# marker names its harness, but only ancestry proves which harness owns this
# process tree, so a structural (comm) ancestor of a DIFFERENT harness wins.
#   - No ancestry match: the marker is the only evidence there is.
#   - No marker: ancestry is the only evidence there is.
#   - Same family: keep the marker's verdict, which is the more specific one
#     (pi-signed, which ancestry can only see as pi).
#   - Different harness, structural ancestor: ancestry wins. This is what stops
#     an inherited or multiplexer-retained CLAUDECODE from renaming a markerless
#     codex, opencode, kimi, or muse session, and symmetrically stops a retained
#     CURSOR_AGENT from renaming a claude worker nested under cursor.
#   - Different harness, interpreter-args ancestor only: the marker wins, because
#     a harness-shaped path in some node process's arguments is weaker evidence
#     than a harness publishing its own identity.
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
  if [ "$(harness_family "$marker")" = "$(harness_family "$harness")" ]; then
    echo "$marker"
    return
  fi
  if [ "$strength" = comm ]; then echo "$harness"; else echo "$marker"; fi
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Print the first non-empty, non-comment line of config/secondmate-harness
# (leading/trailing whitespace trimmed), or nothing when the file is absent or
# holds only blank/comment lines.
secondmate_line() {
  local line
  [ -f "$CONFIG/secondmate-harness" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$CONFIG/secondmate-harness"
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved secondmate_line, or nothing if the line or that field is absent.
secondmate_field() {
  local idx=$1 line
  line=$(secondmate_line)
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> own. An absent or
# "default" secondmate-harness token defers to the crew resolution, so an unset
# secondmate-harness behaves exactly as before this knob existed (a secondmate
# launched on the crew harness). config/secondmate-harness is the PRIMARY's own
# setting and is never inherited downstream - secondmates do not spawn secondmates.
resolve_secondmate() {
  local sm
  sm=$(secondmate_field 1)
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; else echo "$sm"; fi
}

# Print the optional model token (2nd field) from config/secondmate-harness, or
# empty when the harness token is absent/"default" (harness-only file, same as
# today) or when no model token is present.
resolve_secondmate_model() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2
}

# Print the optional effort token (3rd field) from config/secondmate-harness,
# the same way.
resolve_secondmate_effort() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3
}

case "${1:-}" in
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
  secondmate) resolve_secondmate ;;
  secondmate-model) resolve_secondmate_model ;;
  secondmate-effort) resolve_secondmate_effort ;;
  *) detect_own ;;
esac
