#!/usr/bin/env bash
# Install or verify Firstmate's machine-managed Claude Remote Control policy.
# Usage: fm-claude-rc-off.sh install-policy
#        fm-claude-rc-off.sh verify-policy
# Claude's managed settings outrank command-line, project, and user settings.
# Production policy is root-owned and must not be group- or world-writable.
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

verify_policy() {
  local target uid mode
  target=$(policy_path)
  [ -f "$target" ] && [ ! -L "$target" ] || die "managed RC-off policy missing or unsafe: $target; run this helper's install-policy command with system privileges"
  jq -e 'type == "object" and .disableRemoteControl == true' "$target" >/dev/null 2>&1 \
    || die "managed RC-off policy is invalid: $target"
  if [ -z "${FM_TEST_CLAUDE_MANAGED_SETTINGS_DIR:-}" ]; then
    case "$(uname -s)" in
      Linux) read -r uid mode < <(stat -c '%u %a' "$target") ;;
      Darwin) read -r uid mode < <(stat -f '%u %Lp' "$target") ;;
      *) die "unsupported platform: $(uname -s)" ;;
    esac
    [ "$uid" = 0 ] || die "managed RC-off policy is not root-owned: $target"
    (( (8#$mode & 8#022) == 0 )) || die "managed RC-off policy is group- or world-writable: $target"
  fi
  printf 'Claude managed RC-off policy verified: %s\n' "$target"
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
  verify_policy
  printf 'Claude managed RC-off policy installed: %s\n' "$target"
}

case "${1:-}" in
  install-policy) [ "$#" -eq 1 ] || die 'install-policy takes no arguments'; install_policy ;;
  verify-policy) [ "$#" -eq 1 ] || die 'verify-policy takes no arguments'; verify_policy ;;
  --help|-h|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
