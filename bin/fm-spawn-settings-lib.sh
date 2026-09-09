#!/usr/bin/env bash
[ -n "${_FM_SPAWN_SETTINGS_LIB_LOADED:-}" ] && return 0
_FM_SPAWN_SETTINGS_LIB_LOADED=1

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Build the --settings JSON for claude crew launches. Merges enabledPlugins
# entries from config/crew-disabled-plugins (one plugin id per line; # comments
# and blank lines ignored) into the base attribution+feedbackDrafts object.
# Prints the full JSON value (no surrounding shell quotes) to stdout.
# Empirically confirmed mechanism (2026-09-09): --settings is the only scope
# that prevents a user-enabled plugin's hooks from loading in a crew session;
# project-level settings.local.json enabledPlugins does not override the
# user-level enable. See docs/configuration.md "Crew plugin suppression".
build_crew_settings_json() {
  local config_dir=$1 disabled_file plugins_json="" id_escaped line
  disabled_file="$config_dir/crew-disabled-plugins"
  if [ -f "$disabled_file" ]; then
    while IFS= read -r line; do
      line=${line%%#*}   # strip inline comments
      # shellcheck disable=SC2001
      line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$line" ] || continue
      id_escaped=$(json_escape "$line")
      if [ -z "$plugins_json" ]; then
        plugins_json="\"$id_escaped\":false"
      else
        plugins_json="$plugins_json,\"$id_escaped\":false"
      fi
    done < "$disabled_file"
  fi
  if [ -n "$plugins_json" ]; then
    printf '{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false},"enabledPlugins":{%s}}' "$plugins_json"
  else
    printf '%s' '{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false}}'
  fi
}
