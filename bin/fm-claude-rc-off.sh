#!/usr/bin/env bash
# Install or check Firstmate's best-effort managed Claude Remote Control default.
# Usage: fm-claude-rc-off.sh install-policy
#        fm-claude-rc-off.sh check-default [claude-executable]
# The check confirms a supported Claude version and Firstmate's managed fragment.
# It cannot prove the effective value after later drop-ins or higher managed tiers.
# Tests may redirect the managed directory only under FM_SPAWN_NO_GUARD=1.
set -euo pipefail

die() { printf 'fm-claude-rc-off: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

managed_dir() {
  if [ -n "${FM_TEST_CLAUDE_MANAGED_SETTINGS_DIR:-}" ]; then
    [ "${FM_SPAWN_NO_GUARD:-0}" = 1 ] || die 'test managed-settings override requires FM_SPAWN_NO_GUARD=1'
    case "$FM_TEST_CLAUDE_MANAGED_SETTINGS_DIR" in /*) ;; *) die 'test managed-settings directory must be absolute' ;; esac
    printf '%s\n' "$FM_TEST_CLAUDE_MANAGED_SETTINGS_DIR"
    return
  fi
  case "$(uname -s)" in
    Linux) printf '%s\n' /etc/claude-code/managed-settings.d ;;
    Darwin) printf '%s\n' '/Library/Application Support/ClaudeCode/managed-settings.d' ;;
    *) die "unsupported platform: $(uname -s)" ;;
  esac
}

policy_path() {
  printf '%s/50-firstmate-remote-control.json\n' "$(managed_dir)"
}

check_version() {
  local executable=$1 version major minor patch
  version=$("$executable" --version) || die "cannot read Claude version from $executable"
  [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)[[:space:]]+\(Claude\ Code\)$ ]] \
    || die "unrecognized Claude version from $executable: $version"
  major=${BASH_REMATCH[1]}
  minor=${BASH_REMATCH[2]}
  patch=${BASH_REMATCH[3]}
  (( major > 2 || (major == 2 && (minor > 1 || (minor == 1 && patch >= 128))) )) \
    || die "Claude $version does not honor disableRemoteControl"
}

check_policy_fragment() {
  local target uid mode
  target=$(policy_path)
  [ -f "$target" ] && [ ! -L "$target" ] || die "managed RC-off default missing or unsafe: $target; run this helper's install-policy command with system privileges"
  jq -e 'type == "object" and .disableRemoteControl == true' "$target" >/dev/null 2>&1 \
    || die "managed RC-off default is invalid: $target"
  if [ -z "${FM_TEST_CLAUDE_MANAGED_SETTINGS_DIR:-}" ]; then
    case "$(uname -s)" in
      Linux) read -r uid mode < <(stat -c '%u %a' "$target") ;;
      Darwin) read -r uid mode < <(stat -f '%u %Lp' "$target") ;;
      *) die "unsupported platform: $(uname -s)" ;;
    esac
    [ "$uid" = 0 ] || die "managed RC-off default is not root-owned: $target"
    (( (8#$mode & 8#022) == 0 )) || die "managed RC-off default is group- or world-writable: $target"
  fi
  printf '%s\n' "$target"
}

check_default() {
  [ "$#" -le 1 ] || die 'check-default accepts at most one Claude executable'
  local executable=${1:-claude} target
  check_version "$executable"
  target=$(check_policy_fragment)
  printf 'Claude best-effort managed RC-off default present; effective state unverified: %s\n' "$target"
}

install_policy() {
  local dir target tmp
  dir=$(managed_dir)
  target=$(policy_path)
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.50-firstmate-remote-control.XXXXXX")
  trap 'rm -f "$tmp"' RETURN
  printf '%s\n' '{"disableRemoteControl":true}' > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$target"
  trap - RETURN
  target=$(check_policy_fragment)
  printf 'Claude best-effort managed RC-off default installed; effective state unverified: %s\n' "$target"
}

case "${1:-}" in
  install-policy) [ "$#" -eq 1 ] || die 'install-policy takes no arguments'; install_policy ;;
  check-default) shift; check_default "$@" ;;
  --help|-h|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
