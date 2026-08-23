#!/usr/bin/env bash
# The single owner of the config/claude-account pin: which Claude
# credential/config store a home's launches must bill, and what makes a pin
# usable. Sourced by bin/fm-spawn.sh, the launch owner, and by
# bin/fm-control.sh, which asks the same question BEFORE it stops a running
# agent. This file is sourced by scripts and has no side effects on source.
#
# Why one owner: the launch owner's refusal is the authoritative one, but it is
# reached only after the control plane has already stopped the previous agent,
# so a relaunch whose pin went bad would leave the task with no agent at all.
# The control plane therefore has to ask the same question on the pre-stop side
# of its transaction. Two independent implementations of "is this pin usable"
# would drift into a control plane that lets through a launch the launch owner
# refuses, which is exactly the stranded-agent case the pre-stop check exists to
# prevent. The cut lives here so both callers can only ever agree.
#
# docs/configuration.md "Claude account store (config/claude-account)" owns the
# file's schema and operator-facing contract; this file owns the mechanics.

# shellcheck source=bin/fm-config-line-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-config-line-lib.sh"

# Set by fm_claude_account_resolve. FM_CLAUDE_ACCOUNT_PINNED is 1 only when a
# pin file governed the answer; FM_CLAUDE_ACCOUNT_STORE then holds the validated
# store, and otherwise holds the invoking environment's own CLAUDE_CONFIG_DIR
# (possibly empty), which is the unpinned single-store default.
# shellcheck disable=SC2034 # Output global consumed by sourcing callers.
FM_CLAUDE_ACCOUNT_STORE=
# shellcheck disable=SC2034 # Output global consumed by sourcing callers.
FM_CLAUDE_ACCOUNT_PINNED=0

# fm_claude_account_resolve <config-dir> <subject>: resolve the Claude store a
# launch out of the home owning <config-dir> must use. Prints an actionable
# error naming <subject> and the path and returns 1 when a pin exists but is
# unusable; never falls back to the invoking account in that case, because
# silently billing the wrong subscription is the failure the pin prevents.
# shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
fm_claude_account_resolve() {  # <config-dir> <subject>
  local config_dir=$1 subject=$2 pin_file value
  FM_CLAUDE_ACCOUNT_STORE=
  FM_CLAUDE_ACCOUNT_PINNED=0
  pin_file="$config_dir/claude-account"
  # An existing config/ that cannot be searched makes every test below it lie:
  # stat of the pin file fails, so a pin that IS set reads as absent and the
  # launch quietly falls back to the primary's account. Refuse first, so "no
  # pin" is only ever concluded from a directory this user can actually look in.
  # A config/ that does not exist at all is the ordinary unpinned case and is
  # left exactly as before.
  if [ -e "$config_dir" ] && { [ ! -d "$config_dir" ] || [ ! -x "$config_dir" ]; }; then
    echo "error: $subject may pin a Claude account at $pin_file, but $config_dir is not a searchable directory for this user, so an absent pin cannot be told apart from an unreadable one; fix its permissions (launching would bill the primary's Claude account instead)" >&2
    return 1
  fi
  if [ ! -e "$pin_file" ]; then
    # A dangling symlink is a pin the operator meant to set, not an absent one.
    if [ -L "$pin_file" ]; then
      echo "error: $subject pins a Claude account at $pin_file, but that path is a broken symlink; repair or remove it (launching would bill the primary's Claude account instead)" >&2
      return 1
    fi
    FM_CLAUDE_ACCOUNT_STORE=${CLAUDE_CONFIG_DIR:-}
    return 0
  fi
  if [ ! -f "$pin_file" ] || [ ! -r "$pin_file" ]; then
    echo "error: $subject pins a Claude account at $pin_file, but that is not a readable regular file; fix or remove it (launching would bill the primary's Claude account instead)" >&2
    return 1
  fi
  value=$(fm_config_first_line "$pin_file")
  if [ -z "$value" ]; then
    echo "error: $subject has an empty Claude account pin at $pin_file; put the absolute path of its Claude config store on the first line, or remove the file to use the primary's account" >&2
    return 1
  fi
  case "$value" in
    /*) ;;
    *)
      echo "error: $subject pins Claude account store '$value' in $pin_file, which is not an absolute path; use the store directory's full path" >&2
      return 1
      ;;
  esac
  case "/$value/" in
    */../*|*/./*)
      echo "error: $subject pins Claude account store '$value' in $pin_file, which contains traversal components; use the store directory's resolved path" >&2
      return 1
      ;;
  esac
  if [ ! -d "$value" ]; then
    echo "error: $subject pins Claude account store '$value' in $pin_file, but no such directory exists; create it and authenticate that store once with CLAUDE_CONFIG_DIR='$value' claude, or correct the pin" >&2
    return 1
  fi
  if [ ! -r "$value" ] || [ ! -x "$value" ]; then
    echo "error: $subject pins Claude account store '$value' in $pin_file, but that directory is not readable and searchable by this user; fix its permissions or correct the pin" >&2
    return 1
  fi
  FM_CLAUDE_ACCOUNT_STORE=$value
  FM_CLAUDE_ACCOUNT_PINNED=1
  return 0
}
