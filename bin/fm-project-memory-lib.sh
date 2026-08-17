# shellcheck shell=bash
# Local opt-out knob for the ship-brief "Project memory" contract
# (config/project-memory; see docs/configuration.md "Project memory").
#
# Some captains forbid committing AGENTS.md/CLAUDE.md into project repos (agent
# rules live in a machine-level CLAUDE.md instead), so bin/fm-brief.sh and
# bin/fm-ensure-agents-md.sh both consult this file rather than assuming every
# fleet wants a project-committed memory file.
#
# Usage: . bin/fm-project-memory-lib.sh
#
# fm_project_memory_value <config-dir>
#   Echoes the trimmed content of <config-dir>/project-memory, or "on" when the
#   file is absent or empty. Any content other than the exact literal "off" is
#   treated as "on" so an unrecognized value fails open to the pre-existing
#   default rather than silently disabling the contract.
# fm_project_memory_enabled <config-dir>
#   True (exit 0) unless fm_project_memory_value is exactly "off".

fm_project_memory_value() {
  local config_dir=$1 knob_file value
  knob_file="$config_dir/project-memory"
  if [ -f "$knob_file" ]; then
    value=$(tr -d '[:space:]' < "$knob_file" 2>/dev/null || true)
    [ -n "$value" ] || value=on
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' on
}

fm_project_memory_enabled() {
  local config_dir=$1
  [ "$(fm_project_memory_value "$config_dir")" != off ]
}
