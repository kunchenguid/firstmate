# shellcheck shell=bash
# Shared per-harness effort-axis table.
# Usage: . bin/fm-launch-axis-lib.sh
#
# Single owner of which effort levels actually reach a verified adapter's launch
# command. bin/fm-spawn.sh builds the launch flag from it; bin/fm-harness.sh's
# escalation ladder asks the same table whether raising a rung would change the
# launch at all, so the two can never disagree about a harness's effort support.
# Only verified CLI flags belong here: an unsupported level is omitted from the
# launch rather than guessed, and its absence IS the "does not reach" signal.

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort, and the
      # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
      # only low|medium|high and rejects both xhigh and max, so omit those rather
      # than passing a known-bad value.
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    pi|pi-signed)
      # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
      # its --thinking flag.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    muse)
      # Muse accepts low..xhigh directly; its maximum class is named ultra.
      # Omission keeps Muse's native default, so ultra is reachable only from
      # an explicit shared max selection.
      case "$effort" in
        low|medium|high|xhigh) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
        max) printf -- '--reasoning-effort %s ' "$(shell_quote ultra)" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
    # kimi likewise has no reasoning-effort flag; the requested axis stays in
    # task metadata but never reaches the launch command. Cursor Agent expresses
    # effort in the selected model id or its bracket parameters, so firstmate
    # records the separate effort axis but emits no second CLI flag.
  esac
}

# fm_effort_axis_state <harness> <effort>: how the requested level reaches the
# launch command. Prints one of:
#   supported   - the level becomes a launch flag
#   capped      - the harness has an effort flag but not at this level
#   unsupported - the harness has no effort flag at any level
# Derived from effort_flag_for_harness alone, so the table above stays the only
# place a harness's effort support is written down.
fm_effort_axis_state() {
  local harness=$1 effort=$2 probe
  if [ -n "$(effort_flag_for_harness "$harness" "$effort")" ]; then
    printf 'supported\n'
    return 0
  fi
  for probe in low medium high xhigh max; do
    if [ -n "$(effort_flag_for_harness "$harness" "$probe")" ]; then
      printf 'capped\n'
      return 0
    fi
  done
  printf 'unsupported\n'
}
