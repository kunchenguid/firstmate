# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatibility is proved by one live, disposable-fixture probe: `update
# --archive-body` must preserve the replaced body outside the backlog, and a
# two-ID `mv` must reject an incomplete set without mutation before moving the
# complete set together. Version and help output are advisory and never gates.
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.

fm_tasks_axi_compatible() {
  local probe source destination replacement previous
  command -v tasks-axi >/dev/null 2>&1 || return 1
  probe=$(mktemp -d "${TMPDIR:-/tmp}/fm-tasks-axi-probe.XXXXXX") || return 1
  source="$probe/source.md"
  destination="$probe/destination.md"
  replacement='replacement probe body'
  previous='previous probe body'

  printf '%s\n' \
    '## Queued' \
    '- [ ] fm-probe-a - first probe item (repo: firstmate)' \
    "  $previous" \
    '- [ ] fm-probe-b - second probe item (repo: firstmate)' \
    '  second probe body' > "$source"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$destination"

  if ! tasks-axi update fm-probe-a --file "$source" --body "$replacement" --archive-body >/dev/null 2>&1 ||
    ! grep -Fqx "  $replacement" "$source" ||
    grep -Fqx "  $previous" "$source" ||
    ! grep -R -Fqx "  $previous" "$probe" 2>/dev/null; then
    rm -rf "$probe"
    return 1
  fi

  # A failed two-ID move must not leave the valid item half-moved.
  if tasks-axi mv fm-probe-a fm-probe-missing --file "$source" --to "$destination" >/dev/null 2>&1 ||
    ! grep -Fq 'fm-probe-a' "$source" ||
    grep -Fq 'fm-probe-a' "$destination"; then
    rm -rf "$probe"
    return 1
  fi

  if ! tasks-axi mv fm-probe-a fm-probe-b --file "$source" --to "$destination" >/dev/null 2>&1 ||
    grep -Eq 'fm-probe-a|fm-probe-b' "$source" ||
    ! grep -Fq 'fm-probe-a' "$destination" ||
    ! grep -Fq 'fm-probe-b' "$destination"; then
    rm -rf "$probe"
    return 1
  fi

  rm -rf "$probe"
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
