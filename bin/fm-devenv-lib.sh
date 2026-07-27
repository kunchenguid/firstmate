#!/usr/bin/env bash
# shellcheck shell=bash
# fm-devenv-lib.sh - parse and validate Expanly's existing devenv registry.
#
# Source this library from control-plane commands. The registry file contains a
# JSON array of feature-environment objects with name, vm, slot, frontend_port,
# and branch fields. Main is intentionally synthesized here so all callers use
# one complete, validated environment set.
#
# Public functions:
#   fm_devenv_name_valid <name>
#   fm_devenv_vm_valid <vm>
#   fm_devenv_registry_json <registry-path>
#   fm_devenv_registry_get <registry-path> <environment-name>

fm_devenv_name_valid() {  # <name>
  [[ ${1-} =~ ^[A-Za-z0-9_-]+$ ]]
}

fm_devenv_vm_valid() {  # <vm>
  [[ ${1-} =~ ^expanly-[A-Za-z0-9_-]+$ ]]
}

fm_devenv_registry_error() {  # <message>
  printf 'fm-devenv-registry: %s\n' "$1" >&2
  return 1
}

fm_devenv_registry_json() {  # <registry-path>
  local registry_path=${1-} entry_error duplicate
  [ "$#" -eq 1 ] || {
    fm_devenv_registry_error 'expected one registry path'
    return 1
  }
  [ -f "$registry_path" ] || {
    fm_devenv_registry_error "registry is not a readable file: $registry_path"
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    fm_devenv_registry_error 'jq is required'
    return 1
  }
  jq -e -s 'length == 1' "$registry_path" >/dev/null 2>&1 || {
    fm_devenv_registry_error "invalid JSON: $registry_path"
    return 1
  }
  jq -e 'type == "array"' "$registry_path" >/dev/null 2>&1 || {
    fm_devenv_registry_error "registry root must be an array: $registry_path"
    return 1
  }

  entry_error=$(jq -r '
    [
      range(0; length) as $index
      | .[$index] as $entry
      | if ($entry | type) != "object" then
          "entry \($index) must be an object"
        elif (($entry.name | type) != "string") then
          "entry \($index) name must be a string"
        elif ($entry.name | test("^[A-Za-z0-9_-]+$") | not) then
          "entry \($index) has an invalid name: \($entry.name)"
        elif ($entry.name == "main") then
          "entry \($index) must not be named main"
        elif (($entry.vm | type) != "string") then
          "entry \($index) vm must be a string"
        elif ($entry.vm | test("^expanly-[A-Za-z0-9_-]+$") | not) then
          "entry \($index) has an invalid VM name: \($entry.vm)"
        elif (($entry.slot | type) != "number" or ($entry.slot | floor) != $entry.slot) then
          "entry \($index) slot must be an integer"
        elif ($entry.slot <= 0) then
          "entry \($index) slot must be greater than zero"
        elif (($entry.frontend_port | type) != "number" or ($entry.frontend_port | floor) != $entry.frontend_port) then
          "entry \($index) frontend_port must be an integer"
        elif ($entry.frontend_port < 1 or $entry.frontend_port > 65535) then
          "entry \($index) frontend_port must be between 1 and 65535"
        elif (($entry.branch | type) != "string") then
          "entry \($index) branch must be a string"
        else
          empty
        end
    ] | .[0] // empty
  ' "$registry_path") || {
    fm_devenv_registry_error "could not inspect registry: $registry_path"
    return 1
  }
  [ -z "$entry_error" ] || {
    fm_devenv_registry_error "$entry_error"
    return 1
  }

  for duplicate in name vm slot frontend_port; do
    entry_error=$(jq -r --arg field "$duplicate" '
      [{name:"main", vm:"expanly-main", slot:0, frontend_port:5173, branch:""}] + .
      | group_by(.[$field])
      | map(select(length > 1) | .[0][$field])
      | .[0] // empty
    ' "$registry_path") || {
      fm_devenv_registry_error "could not inspect registry: $registry_path"
      return 1
    }
    [ -z "$entry_error" ] || {
      fm_devenv_registry_error "duplicate $duplicate: $entry_error"
      return 1
    }
  done

  jq '
    [{name:"main", vm:"expanly-main", slot:0, frontend_port:5173, branch:""}] + .
    | sort_by(.slot)
    | map({name, vm, slot, frontend_port, branch})
  ' "$registry_path"
}

fm_devenv_registry_get() {  # <registry-path> <environment-name>
  local registry_path=${1-} name=${2-}
  [ "$#" -eq 2 ] || return 1
  fm_devenv_name_valid "$name" || return 1
  fm_devenv_registry_json "$registry_path" | jq -ce --arg name "$name" '.[] | select(.name == $name)'
}
