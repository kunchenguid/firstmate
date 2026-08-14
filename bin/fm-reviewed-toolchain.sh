#!/usr/bin/env bash
# Reviewed npm toolchain owner for Firstmate's required AXI interfaces and the
# browser transport they launch.
#
# Usage:
#   fm-reviewed-toolchain.sh version <tool>
#   fm-reviewed-toolchain.sh npm-spec <tool>
#   fm-reviewed-toolchain.sh global-entrypoint chrome-devtools-mcp
#   fm-reviewed-toolchain.sh check <tool>
#   fm-reviewed-toolchain.sh install <tool>...
#
# `version` is the single authoritative reviewed-version registry.
# `check` requires exact equality rather than a floor. A mismatch is diagnostic
# only until the operator approves `fm-bootstrap.sh install <tool>`; no startup
# path invokes `install` or changes a global package unattended.
#
# chrome-devtools-mcp is intentionally checked through its npm-global package
# directory, not only a PATH shim. Its entrypoint is resolved from `npm prefix
# -g`, matching chrome-devtools-axi's stable direct-node transport discovery and
# preventing a correctly provisioned home from falling through to npx latest.
set -u

fm_reviewed_tool_version() {  # <tool>
  case "$1" in
    gh-axi) printf '%s\n' 0.1.30 ;;
    chrome-devtools-axi) printf '%s\n' 0.1.29 ;;
    lavish-axi) printf '%s\n' 0.1.50 ;;
    quota-axi) printf '%s\n' 0.1.25 ;;
    tasks-axi) printf '%s\n' 0.2.5 ;;
    chrome-devtools-mcp) printf '%s\n' 1.7.0 ;;
    *) return 1 ;;
  esac
}

fm_reviewed_npm_spec() {  # <tool>
  local version
  version=$(fm_reviewed_tool_version "$1") || return 1
  printf '%s@%s\n' "$1" "$version"
}

fm_reviewed_mcp_entrypoint() {
  local prefix
  command -v npm >/dev/null 2>&1 || return 1
  prefix=$(npm prefix -g 2>/dev/null) || return 1
  [ -n "$prefix" ] || return 1
  printf '%s/lib/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js\n' "${prefix%/}"
}

fm_reviewed_mcp_package_json() {
  local entrypoint
  entrypoint=$(fm_reviewed_mcp_entrypoint) || return 1
  printf '%s\n' "${entrypoint%/build/src/bin/chrome-devtools-mcp.js}/package.json"
}

fm_reviewed_package_json_field() {  # <package-json> <field>
  local package_json=$1 field=$2
  [ -f "$package_json" ] && [ ! -L "$package_json" ] || return 1
  sed -nE "s/^[[:space:]]*\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\\1/p" "$package_json" | head -n 1
}

fm_reviewed_installed_version() {  # <tool>
  local tool=$1 output package_json name
  if [ "$tool" = chrome-devtools-mcp ]; then
    package_json=$(fm_reviewed_mcp_package_json) || return 1
    name=$(fm_reviewed_package_json_field "$package_json" name) || return 1
    [ "$name" = chrome-devtools-mcp ] || return 1
    fm_reviewed_package_json_field "$package_json" version
    return $?
  fi
  command -v "$tool" >/dev/null 2>&1 || return 1
  output=$("$tool" --version 2>/dev/null </dev/null) || return 1
  printf '%s\n' "$output" |
    sed -nE 's/.*[vV]?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' |
    head -n 1
}

fm_reviewed_tool_compatible() {  # <tool>
  local tool=$1 expected installed entrypoint
  expected=$(fm_reviewed_tool_version "$tool") || return 1
  installed=$(fm_reviewed_installed_version "$tool") || return 1
  [ "$installed" = "$expected" ] || return 1
  if [ "$tool" = chrome-devtools-mcp ]; then
    entrypoint=$(fm_reviewed_mcp_entrypoint) || return 1
    [ -f "$entrypoint" ] && [ ! -L "$entrypoint" ] || return 1
  fi
}

fm_reviewed_install() {  # <tool>...
  local tool spec
  [ "$#" -gt 0 ] || return 1
  command -v npm >/dev/null 2>&1 || {
    printf 'fm-reviewed-toolchain: npm is required\n' >&2
    return 1
  }
  for tool in "$@"; do
    spec=$(fm_reviewed_npm_spec "$tool") || {
      printf 'fm-reviewed-toolchain: unknown reviewed tool: %s\n' "$tool" >&2
      return 1
    }
    printf 'installing %s: npm install -g %s\n' "$tool" "$spec"
    npm install -g "$spec" || return $?
  done
}

fm_reviewed_usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" >&2
}

fm_reviewed_main() {
  local command=${1:-} tool version entrypoint
  [ "$#" -gt 0 ] && shift
  case "$command" in
    version)
      [ "$#" -eq 1 ] || { fm_reviewed_usage; return 2; }
      fm_reviewed_tool_version "$1" || return 2
      ;;
    npm-spec)
      [ "$#" -eq 1 ] || { fm_reviewed_usage; return 2; }
      fm_reviewed_npm_spec "$1" || return 2
      ;;
    global-entrypoint)
      [ "$#" -eq 1 ] && [ "$1" = chrome-devtools-mcp ] || { fm_reviewed_usage; return 2; }
      fm_reviewed_mcp_entrypoint
      ;;
    check)
      [ "$#" -eq 1 ] || { fm_reviewed_usage; return 2; }
      tool=$1
      version=$(fm_reviewed_tool_version "$tool") || return 2
      fm_reviewed_tool_compatible "$tool" || return 1
      printf '%s@%s\n' "$tool" "$version"
      if [ "$tool" = chrome-devtools-mcp ]; then
        entrypoint=$(fm_reviewed_mcp_entrypoint) || return 1
        printf 'entrypoint=%s\n' "$entrypoint"
      fi
      ;;
    install)
      [ "$#" -gt 0 ] || { fm_reviewed_usage; return 2; }
      fm_reviewed_install "$@"
      ;;
    -h|--help|help)
      fm_reviewed_usage
      ;;
    *)
      fm_reviewed_usage
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_reviewed_main "$@"
fi
