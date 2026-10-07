#!/usr/bin/env bash
# fm-features-lib.sh - per-home feature switches.
#
# A home may turn whole optional features off so a smaller team fleet loads and
# runs only what it uses. This file is the single owner of the switch names,
# the file format, and the effective verdict; bin/fm-features.sh is the
# operator command, and docs/configuration.md "Feature switches" is the
# operator reference.
#
# Declaration: config/features in the active home, one `<name>=on|off` per line.
# Blank lines and lines starting with `#` are ignored. A missing file or a
# missing line means `on`, so a home that never declared switches keeps every
# feature exactly as before. `on` is not an opt-in by itself: a feature that has
# its own upstream opt-in (a Relay token, config/trace-context, config/voice-*,
# a registered secondmate) still needs it; `off` overrides that opt-in.
# An unknown name or value is ignored with a warning from fm-features.sh show,
# never a refusal, so a newer preset never stops an older checkout.
#
# Switch names (keep FM_FEATURE_NAMES and docs/configuration.md in step):
#   secondmate      secondmate homes, local and remote
#   relay           Relay public mentions (X and Discord)
#   voice-ide       spoken relay, model-backed inbox say/ask, IDE extension bindings
#   no-mistakes     the no-mistakes delivery mode and its pipeline
#   local-only      the local-only delivery mode and scout-to-ship promotion
#   contributions   published-contribution observation
#   process-events  condition-action watches and trusted extension adapters
#                   (the built-in Lavish board, quota, and reply sources stay)
#   trace           W3C trace-context propagation

FM_FEATURE_NAMES="secondmate relay voice-ide no-mistakes local-only contributions process-events trace"

# Echo the config directory for the active home, honoring the same override the
# other scripts use.
fm_features_config_dir() {
  local home=${FM_HOME:-}
  if [ -z "$home" ]; then
    home=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
  fi
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$home/config}"
}

fm_feature_known() {  # <name>
  case " $FM_FEATURE_NAMES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Echo the declared value (on|off) for <name> in <config-dir>, or nothing.
fm_feature_declared() {  # <config-dir> <name>
  local file=$1/features
  [ -f "$file" ] || return 0
  awk -F= -v want="$2" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      k = $1; v = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (k == want && (v == "on" || v == "off")) last = v
    }
    END { if (last != "") print last }
  ' "$file" 2>/dev/null
}

# True unless <name> is switched off in <config-dir>.
fm_feature_enabled_in() {  # <config-dir> <name>
  [ "$(fm_feature_declared "$1" "$2")" != off ]
}

# True unless <name> is switched off in the active home.
fm_feature_enabled() {  # <name>
  fm_feature_enabled_in "$(fm_features_config_dir)" "$1"
}

# Refuse a delivery mode whose feature this home switched off. <caller> names
# the refusing script in the message.
fm_feature_mode_allowed() {  # <mode> <caller>
  local mode=$1 caller=$2 feature
  case "$mode" in
    no-mistakes) feature=no-mistakes ;;
    local-only) feature=local-only ;;
    *) return 0 ;;
  esac
  fm_feature_enabled "$feature" && return 0
  echo "error: $caller: --mode $mode is switched off in this home (config/features); ship direct-PR, or turn it on with bin/fm-features.sh set $feature on" >&2
  return 1
}
