#!/usr/bin/env bash
# fm-opencode-ladder-lib.sh - the opencode free-then-Go ladder, enforced at dispatch.
# Usage: . bin/fm-opencode-ladder-lib.sh
# Sourced by bin/fm-spawn.sh. Sourcing has no side effects beyond the rung
# constants below.
#
# THE POLICY. The captain's standing rule for opencode dispatch is a fixed
# two-rung ladder run by PROVEN EXHAUSTION, not load balancing: rung 1 is the
# free tier, rung 2 is the paid Go tier, same model (muse spark 1.3), different
# provider prefix. Work runs on free first each day; new spawns fall through
# to Go only once free is proven exhausted; work climbs straight back the
# moment free resets. The rungs are stated once, here, as constants - there is
# no config order to derive, because the order is fixed by economics rather
# than ranked by the captain.
#
# REACTIVE, NOT PREDICTIVE - AND THAT IS THE HONEST DIFFERENCE FROM AGY. The
# agy ladder reads quota percentages before spending (bin/fm-agy-ladder-lib.sh
# owns that shape), so it refuses a rung BEFORE the floor is crossed. quota-axi
# reports nothing for opencode - `quota-axi --provider opencode` answers
# "unsupported provider" - so there is no reading to decide on and no floor to
# refuse ahead of. This ladder decides AFTER the fact, on the refusal the
# vendor already issued: bin/fm-opencode-retry.sh classifies a lane's own
# retry-backoff horizon as quota-scale, and that classification IS the
# "free is exhausted" signal - plus, since the 2026-09-14 four-lane blind
# spot, the same helper's scan of a lane's pane tail for the cap verbatim,
# which covers lanes that took the error and went idle with no sidecar left.
# A free lane that hits the cap mid-run still spends into the cap before
# anyone knows; this ladder only routes the NEXT spawn. Do not pretend it
# prevents the spend it reacts to.
#
# THE CLIMB-BACK USES THE VENDOR'S OWN HORIZON, NOT A TIMER OF ITS OWN. The
# refusal carries its backoff ("retrying in 21h 54m"), the plugin records it
# as the sidecar's `next` timestamp, and bin/fm-opencode-retry.sh stops
# classifying the sidecar once that time plus grace has passed. So a cap that
# has elapsed simply stops being evidence, and the next spawn climbs back to
# free with nothing here counting down. If the vendor's horizon proves
# unreliable in practice, the remedy is a probe launch on free, not a second
# clock kept beside the vendor's.
#
# RUNNING WORKERS ARE DELIBERATELY NOT TOUCHED. A lane already working on free
# that hits the cap reads `blocked` through bin/fm-crew-state.sh's existing
# override, and it stays on its recorded model: there is no verified
# in-session model switch for opencode (agy's guarded /model walk does not
# transfer), and dragging a live worker across tiers unsupervised would risk
# the conversation for no proven gain. Recovery and relaunch keep the recorded
# model. This file routes the next spawn only, and says so.
#
# THE FAILURE DIRECTION, STATED NOT IMPLIED. Two mistakes are possible: fall
# through to Go when free is actually fine (spends money that did not need
# spending), or refuse to fall through when free is genuinely dead (stalls the
# fleet). This ladder is biased toward falling through, for the captain's own
# throughput-first reason: a stalled fleet is worse than a small early spend.
# That bias cashes out in exactly two places: a quota-scale cap with NO model
# binding still falls through (the notice owns the ambiguity), and NOTHING
# here ever refuses a launch - even a home where both tiers show capped still
# launches on Go and lets the existing per-lane detection report it, rather
# than wedging dispatch. Absence of evidence, however, is never exhaustion: a
# home with no cap evidence at all dispatches free, silently.
#
# THE OVERRIDE. FM_OPENCODE_LADDER_OVERRIDE, set to a non-empty reason, holds
# a free request on free past a proven cap and prints that it did. It is an
# environment variable rather than a flag deliberately, matching the agy
# ladder's override: dispatch profiles carry only harness, model, and effort,
# so holding free stays a deliberate act at the command line.
# FM_OPENCODE_LADDER=off disables the whole gate: the requested model (or free
# when none was requested) passes through unchanged, with a notice naming the
# kill-switch so a bypass never looks like a decision.

# The governed pair. Same model, different provider prefix - the only
# difference between the tiers, as the captain said.
FM_OPENCODE_LADDER_FREE='opencode/muse-spark-1.3-contributor-free'
FM_OPENCODE_LADDER_GO='opencode-go/muse-spark-1.3-contributor'

# Resolve this library's own directory so it can name the retry-evidence
# helper whether it was sourced by a bin/ script or directly by a test.
_FM_OPENCODE_LADDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_OPENCODE_LADDER_LIB_DIR="."
_FM_OPENCODE_LADDER_RETRY="$_FM_OPENCODE_LADDER_LIB_DIR/fm-opencode-retry.sh"
# Backend capture plus the meta readers live in the backend library; callers
# on the dispatch path (bin/fm-spawn.sh) load it before this file, so the
# guarded source below fires only when this file stands alone. Without it the
# sidecar half below still works and the pane-text half degrades to unknown.
# shellcheck source=/dev/null
if ! declare -f fm_backend_capture >/dev/null 2>&1; then
  . "$_FM_OPENCODE_LADDER_LIB_DIR/fm-backend.sh"
fi

# Lines of rendered pane tail handed to the detector for the idle shape.
# bin/fm-opencode-retry.sh owns the phrases; this is only the capture width.
FM_OPENCODE_CAP_TEXT_LINES=${FM_OPENCODE_CAP_TEXT_LINES:-60}

# fm_opencode_ladder_pane_file: capture <id>'s pane tail into a temp file and
# print its path (the caller removes it). Prints nothing and returns 1 when
# the lane has no readable meta, no backend target, no capture primitive, or
# an empty capture: all of those are unknown, never open, and the gate treats
# unknown as dispatch-free (see fm_opencode_ladder_free_capped).
fm_opencode_ladder_pane_file() {  # <state-dir> <id>
  local state_dir=$1 id=$2 meta backend target cap_file
  meta="$state_dir/$id.meta"
  [ -f "$meta" ] || return 1
  command -v fm_backend_capture >/dev/null 2>&1 || return 1
  command -v fm_backend_of_meta >/dev/null 2>&1 || return 1
  command -v fm_backend_target_of_meta >/dev/null 2>&1 || return 1
  backend=$(fm_backend_of_meta "$meta" 2>/dev/null) || return 1
  target=$(fm_backend_target_of_meta "$meta" 2>/dev/null) || return 1
  [ -n "$target" ] || return 1
  cap_file=$(mktemp "${TMPDIR:-/tmp}/fm-opencode-cap.XXXXXX") || return 1
  if ! fm_backend_capture "$backend" "$target" "$FM_OPENCODE_CAP_TEXT_LINES" "fm-$id" \
    > "$cap_file" 2>/dev/null; then
    rm -f "$cap_file"
    return 1
  fi
  [ -s "$cap_file" ] || { rm -f "$cap_file"; return 1; }
  printf '%s\n' "$cap_file"
}

# fm_opencode_ladder_horizon_human: compact "~22h34m" rendering of <seconds>
# for notices. Presentation only; the threshold contract stays owned by
# bin/fm-opencode-retry.sh.
fm_opencode_ladder_horizon_human() {  # <seconds>
  local s=$1 h m
  case "$s" in ''|*[!0-9]*) printf '~?'; return ;; esac
  if [ "$s" -ge 3600 ]; then
    h=$((s / 3600)); m=$(((s % 3600) / 60))
    printf '~%sh%sm' "$h" "$m"
  elif [ "$s" -ge 60 ]; then
    m=$((s / 60)); s=$((s % 60))
    printf '~%sm%ss' "$m" "$s"
  else
    printf '~%ss' "$s"
  fi
}

# fm_opencode_ladder_bare_model: <model> without its provider prefix.
# The retry sidecar's model comes from OpenCode's own event stream (model.id),
# which carries no provider prefix (`muse-spark-1.3-contributor-free`), while
# the rung constants above carry one (`opencode/...`). Every evidence
# comparison normalises both sides through here, so either form binds the
# right rung. The suffix is what separates the tiers once the prefix is gone -
# free stays `...-free` and Go stays bare - so stripping never collapses them.
fm_opencode_ladder_bare_model() {  # <model>
  case "$1" in
    */*) printf '%s' "${1##*/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_opencode_ladder_free_capped: is the free tier proven exhausted on the
# CURRENT evidence in <state-dir>? Prints one line and returns 0 when some
# lane's sidecar classifies quota-scale (`blocked`) through
# bin/fm-opencode-retry.sh and is bound to the free tier - or bound to no tier
# at all, per the stated failure direction - OR when some lane's pane tail
# carries the cap verbatim with no blocking sidecar (the idle shape: the lane
# took the provider error and ended its turn, so the sidecar is gone and the
# rendered text is the only evidence left; bin/fm-opencode-retry.sh owns the
# phrases). Prints nothing and returns 1 on every other path: no sidecars,
# transient backoffs only, expired caps only, a cap bound to the Go tier only,
# clean pane tails, uncapturable panes, an unreadable helper, or an unreadable
# state dir. Absence of evidence is never exhaustion: unknown (no sidecar and
# no usable capture) dispatches free, silently. That allow-on-unknown is the
# captain's standing position - missing evidence must not stall the fleet -
# and it is stated here rather than hidden in the detector so the choice stays
# visible where it licenses the mis-route it risks.
#
# The printed line is "free-capped horizon_s=<s|unknown> bound=<free|unbound>".
# Text-only evidence carries no trustworthy horizon (an idle lane's bracketed
# retry duration may never fire), so it reports horizon_s=unknown and the
# model notice owns that. A text cap on a lane recorded on the free tier binds
# free - the phrase names Go as the remedy, so it is the free tier that is
# exhausted; anywhere else it binds unbound and falls through on the same bias.
fm_opencode_ladder_free_capped() {  # <state-dir>
  local state_dir=$1 f id out word status='' horizon='' model=''
  local free_horizon='' unbound_horizon=''
  local text_free='' text_unbound=''
  local meta harness lane_model lane_bare cap_file
  local free_bare model_bare
  free_bare=$(fm_opencode_ladder_bare_model "$FM_OPENCODE_LADDER_FREE")
  [ -n "$state_dir" ] && [ -d "$state_dir" ] || return 1
  [ -x "$_FM_OPENCODE_LADDER_RETRY" ] || return 1
  for f in "$state_dir"/*.opencode-retry; do
    [ -e "$f" ] || continue
    id=${f##*/}
    id=${id%.opencode-retry}
    out=$("$_FM_OPENCODE_LADDER_RETRY" check "$state_dir" "$id" 2>/dev/null) || continue
    status=''; horizon=''; model=''
    for word in $out; do
      case "$word" in
        status=*) status=${word#status=} ;;
        horizon_s=*) horizon=${word#horizon_s=} ;;
        model=*) model=${word#model=} ;;
      esac
    done
    [ "$status" = blocked ] || continue
    case "$horizon" in ''|*[!0-9]*) continue ;; esac
    model_bare=$(fm_opencode_ladder_bare_model "$model")
    if [ "$model_bare" = "$free_bare" ]; then
      if [ -z "$free_horizon" ] || [ "$horizon" -gt "$free_horizon" ]; then
        free_horizon=$horizon
      fi
    elif [ -z "$model" ]; then
      if [ -z "$unbound_horizon" ] || [ "$horizon" -gt "$unbound_horizon" ]; then
        unbound_horizon=$horizon
      fi
    fi
    # A cap bound to any other model (notably the Go tier) says nothing about
    # free and is skipped, not counted.
  done
  # The idle shape, per recorded lane: a blocking sidecar already counted above
  # stays counted; every other opencode lane gets its pane tail scanned. A lane
  # whose capture fails is unknown and skipped, never counted.
  if [ -z "$free_horizon" ]; then
    for meta in "$state_dir"/*.meta; do
      [ -e "$meta" ] || continue
      id=$(basename "$meta" .meta)
      case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
      harness=$(fm_meta_get "$meta" harness 2>/dev/null) || continue
      case "$harness" in opencode*) ;; *) continue ;; esac
      # A quota-scale sidecar already counted above stays counted; a merely
      # transient one does not suppress the text scan (for an idle lane the
      # pane text wins over a short-horizon sidecar, as the descent holds).
      if out=$("$_FM_OPENCODE_LADDER_RETRY" check "$state_dir" "$id" 2>/dev/null); then
        case "$out" in status=blocked*) continue ;; esac
      fi
      cap_file=$(fm_opencode_ladder_pane_file "$state_dir" "$id" 2>/dev/null) || continue
      if "$_FM_OPENCODE_LADDER_RETRY" scan-text --file "$cap_file" >/dev/null 2>&1; then
        lane_model=$(fm_meta_get "$meta" model 2>/dev/null) || lane_model=''
        lane_bare=$(fm_opencode_ladder_bare_model "$lane_model")
        if [ "$lane_bare" = "$free_bare" ]; then
          text_free=1
        else
          text_unbound=1
        fi
      fi
      rm -f "$cap_file"
      [ -z "$text_free" ] || break
    done
  fi
  if [ -n "$free_horizon" ]; then
    printf 'free-capped horizon_s=%s bound=free\n' "$free_horizon"
    return 0
  fi
  if [ -n "$text_free" ]; then
    printf 'free-capped horizon_s=unknown bound=free\n'
    return 0
  fi
  if [ -n "$unbound_horizon" ]; then
    printf 'free-capped horizon_s=%s bound=unbound\n' "$unbound_horizon"
    return 0
  fi
  if [ -n "$text_unbound" ]; then
    printf 'free-capped horizon_s=unknown bound=unbound\n'
    return 0
  fi
  return 1
}

# fm_opencode_ladder_model: the model id a launch with <requested> should run.
# Prints exactly one line - the effective model id - on stdout, and the human
# notice (if any) on stderr. Always exits 0: this ladder never refuses, so a
# broken gate degrades to the requested model rather than a stalled fleet.
# An empty or `default` request is free intent: dispatch on free by default.
fm_opencode_ladder_model() {  # <requested> <state-dir>
  local requested=${1:-} state_dir=${2:-} cap='' horizon='' bound=''
  local word effective notice=''
  if [ -z "$requested" ] || [ "$requested" = default ]; then
    requested=$FM_OPENCODE_LADDER_FREE
  fi
  if [ "${FM_OPENCODE_LADDER:-on}" = off ]; then
    printf '%s\n' "$requested"
    printf 'notice: opencode ladder disabled by FM_OPENCODE_LADDER=off - launching on %s unchecked against the free cap\n' \
      "$requested" >&2
    return 0
  fi
  case "$requested" in
    "$FM_OPENCODE_LADDER_FREE")
      if cap=$(fm_opencode_ladder_free_capped "$state_dir" 2>/dev/null); then
        for word in $cap; do
          case "$word" in
            horizon_s=*) horizon=${word#horizon_s=} ;;
            bound=*) bound=${word#bound=} ;;
          esac
        done
        # Text-only evidence carries no horizon: own that instead of printing
        # a broken "next retry in ~?".
        case "$horizon" in
          ''|*[!0-9]*)
            when='the cap is showing in a lane'"'"'s pane with no retry horizon on record' ;;
          *)
            when="next retry in $(fm_opencode_ladder_horizon_human "$horizon")" ;;
        esac
        if [ -n "${FM_OPENCODE_LADDER_OVERRIDE:-}" ]; then
          printf '%s\n' "$FM_OPENCODE_LADDER_FREE"
          printf 'notice: opencode ladder OVERRIDDEN by FM_OPENCODE_LADDER_OVERRIDE=%s - holding free past a proven cap (%s)\n' \
            "$FM_OPENCODE_LADDER_OVERRIDE" "$when" >&2
          return 0
        fi
        effective=$FM_OPENCODE_LADDER_GO
        if [ "$bound" = unbound ]; then
          notice=$(printf 'notice: opencode ladder: free tier %s may be exhausted (a quota-scale retry backoff with no model binding, %s) - biasing toward the Go tier %s rather than stalling; set FM_OPENCODE_LADDER_OVERRIDE=<reason> to hold free' \
            "$FM_OPENCODE_LADDER_FREE" "$when" "$FM_OPENCODE_LADDER_GO")
        else
          notice=$(printf 'notice: opencode ladder: free tier %s is proven exhausted (quota-scale retry backoff, %s) - dispatching on the Go tier %s instead; it climbs back to free once the cap elapses' \
            "$FM_OPENCODE_LADDER_FREE" "$when" "$FM_OPENCODE_LADDER_GO")
        fi
        printf '%s\n' "$effective"
        printf '%s\n' "$notice" >&2
        return 0
      fi
      printf '%s\n' "$FM_OPENCODE_LADDER_FREE"
      return 0
      ;;
    "$FM_OPENCODE_LADDER_GO")
      # An explicit Go request always stands, even while free is capped: the
      # ladder never downgrades a choice the captain made on purpose.
      printf '%s\n' "$FM_OPENCODE_LADDER_GO"
      return 0
      ;;
    *)
      printf '%s\n' "$requested"
      printf 'notice: opencode ladder not applied: model %s is outside the governed free-then-Go pair (%s, %s), so this launch is unchecked against the free cap\n' \
        "$requested" "$FM_OPENCODE_LADDER_FREE" "$FM_OPENCODE_LADDER_GO" >&2
      return 0
      ;;
  esac
}
