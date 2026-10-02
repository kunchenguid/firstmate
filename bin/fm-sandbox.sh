#!/usr/bin/env bash
# fm-sandbox.sh - opt-in, fail-closed worker command sandbox.
#
# docs/configuration.md owns the contract ("Worker command sandbox"); this
# header owns the mechanics.
#
# A home opts in by creating config/worker-sandbox. While that file is absent
# every subcommand is a no-op: `prefix` prints nothing and `exec` runs its
# command unchanged, so default behavior is untouched.
#
# When enabled the wrapper is fail-closed. It never falls back to running the
# command unsandboxed: a missing runtime, a runtime that is not the pinned
# version, an unusable settings file, or a failed live capability probe all
# refuse with an actionable diagnostic instead of executing anything.
#
# Usage:
#   fm-sandbox.sh probe             validate the runtime, the settings file, and
#                                   a live capability probe; exit 0 only when
#                                   ready. Independent of the opt-in flag, so it
#                                   is the evidence command for this host.
#   fm-sandbox.sh prefix            print the shell prefix to prepend to a
#                                   launch command (empty while disabled).
#   fm-sandbox.sh exec -- <cmd...>  run a command under the sandbox
#                                   (passthrough while disabled).
#
# Environment:
#   FM_HOME / FM_CONFIG_OVERRIDE  locate config/worker-sandbox and its settings
#                                 (one of the two is required)
#   FM_SANDBOX_SRT_BIN            override the pinned runtime executable
#   FM_SANDBOX_SETTINGS           override the settings file path
#                                 (default <config>/worker-sandbox-settings.json)
#
# Exit codes: 0 success, 1 refused, 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

# The exact Anthropic sandbox-runtime release this wrapper is proven against.
# A different version refuses rather than running on an unverified interface.
SRT_PINNED_VERSION=0.0.78

usage() {
  sed -n '2,${/^#/!q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

sandbox_squote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

sandbox_config_dir() {
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_CONFIG_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s\n' "$FM_HOME/config"
  else
    echo "error: fm-sandbox.sh needs FM_HOME or FM_CONFIG_OVERRIDE to locate config/worker-sandbox" >&2
    exit 2
  fi
}

# Resolved state, set by the sandbox_* validators below. They set globals
# rather than echoing because a refusal must exit the whole script, and an
# `exit` inside `$(...)` only exits the command substitution.
SANDBOX_SRT=
SANDBOX_SETTINGS=
# The private probe directory, removed before any refusal and after a good
# probe. `exec` replaces this process, so the successful path must clean up
# before it, not through an EXIT trap.
PROBE_DIR=

sandbox_probe_cleanup() {
  if [ -n "$PROBE_DIR" ]; then
    rm -rf "$PROBE_DIR"
    PROBE_DIR=
  fi
}

sandbox_refuse() {  # <reason>
  sandbox_probe_cleanup
  {
    printf 'error: opt-in worker sandbox unavailable: %s\n' "$1"
    printf 'The worker command was NOT run; config/worker-sandbox refuses rather than running unsandboxed.\n'
    printf 'Install the pinned runtime with: npm install -g @anthropic-ai/sandbox-runtime@%s\n' "$SRT_PINNED_VERSION"
    printf 'On Linux the runtime needs working unprivileged user namespaces (bubblewrap); see docs/configuration.md.\n'
  } >&2
  exit 1
}

sandbox_resolve_srt() {
  local bin=${FM_SANDBOX_SRT_BIN:-}
  if [ -z "$bin" ]; then
    bin=$(command -v srt 2>/dev/null) || bin=
  fi
  [ -n "$bin" ] || sandbox_refuse "the pinned sandbox runtime 'srt' is not on PATH"
  [ -x "$bin" ] || sandbox_refuse "sandbox runtime '$bin' is not an executable file"
  SANDBOX_SRT=$bin
}

sandbox_check_version() {
  local out
  if ! out=$("$SANDBOX_SRT" --version 2>/dev/null); then
    sandbox_refuse "could not read the version of $SANDBOX_SRT (its --version failed)"
  fi
  out=$(printf '%s' "$out" | head -n 1 | tr -d '[:space:]')
  [ "$out" = "$SRT_PINNED_VERSION" ] ||
    sandbox_refuse "sandbox runtime version '${out:-unknown}' is not the pinned $SRT_PINNED_VERSION"
}

sandbox_check_settings() {
  local settings
  settings=${FM_SANDBOX_SETTINGS:-$CONFIG/worker-sandbox-settings.json}
  [ -e "$settings" ] || sandbox_refuse "settings file $settings does not exist (set FM_SANDBOX_SETTINGS or create it)"
  [ -f "$settings" ] || sandbox_refuse "settings file $settings is not a regular file"
  [ -r "$settings" ] || sandbox_refuse "settings file $settings is not readable"
  [ -s "$settings" ] || sandbox_refuse "settings file $settings is empty"
  if command -v jq >/dev/null 2>&1; then
    if ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
      sandbox_refuse "settings file $settings is not a JSON object"
    fi
  fi
  SANDBOX_SETTINGS=$settings
}

# Run one sandboxed command that must succeed, with a reason for the refusal.
sandbox_probe_must_pass() {  # <settings> <command> <what>
  if ! "$SANDBOX_SRT" --settings "$1" -c "$2" >/dev/null 2>&1; then
    sandbox_refuse "$3 (the runtime could not run it; on Linux check unprivileged user namespaces/bubblewrap)"
  fi
}

# Prove the pinned runtime actually enforces isolation on this host, using a
# disposable fixture and no real secrets. Reads stay permitted by default and
# writes stay denied except where allowed, so a permitted write must succeed
# while a denied read and a denied write must both fail.
sandbox_live_probe() {
  local secret denied
  command -v jq >/dev/null 2>&1 || sandbox_refuse "jq is required to build the capability probe fixture"
  PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-worker-sandbox-probe.XXXXXX") ||
    sandbox_refuse "could not create a private probe directory under ${TMPDIR:-/tmp}"
  chmod 700 "$PROBE_DIR"
  mkdir "$PROBE_DIR/allow" "$PROBE_DIR/denied" || sandbox_refuse "could not stage the probe fixture"
  secret="$PROBE_DIR/secret"
  denied="$PROBE_DIR/denied"
  printf 'fm-worker-sandbox-probe\n' > "$secret"
  jq -n --arg secret "$secret" --arg allow "$PROBE_DIR/allow" --arg denied "$denied" \
    '{filesystem:{denyRead:[$secret],allowWrite:[$allow],denyWrite:[$denied]},network:{allowedDomains:[],deniedDomains:[]}}' \
    > "$PROBE_DIR/settings.json" || sandbox_refuse "could not write the probe settings"
  sandbox_probe_must_pass "$PROBE_DIR/settings.json" \
    "touch $(sandbox_squote "$PROBE_DIR/allow/ok")" \
    "the runtime did not permit a write its settings allow"
  if "$SANDBOX_SRT" --settings "$PROBE_DIR/settings.json" -c "cat $(sandbox_squote "$secret")" >/dev/null 2>&1; then
    sandbox_refuse "the runtime permitted a read its settings deny; refusing to trust unenforced isolation"
  fi
  if "$SANDBOX_SRT" --settings "$PROBE_DIR/settings.json" -c "touch $(sandbox_squote "$denied/x")" >/dev/null 2>&1; then
    sandbox_refuse "the runtime permitted a write its settings deny; refusing to trust unenforced isolation"
  fi
  sandbox_probe_cleanup
}

# Validate everything; sets SANDBOX_SRT and SANDBOX_SETTINGS.
sandbox_require() {
  sandbox_resolve_srt
  sandbox_check_version
  sandbox_check_settings
  sandbox_probe_must_pass "$SANDBOX_SETTINGS" "true" "the runtime did not accept the supplied settings"
  sandbox_live_probe
}

cmd_probe() {
  sandbox_require
  printf 'worker sandbox ready: %s (pinned %s), settings %s\n' "$SANDBOX_SRT" "$SRT_PINNED_VERSION" "$SANDBOX_SETTINGS"
}

cmd_prefix() {
  if [ "$SANDBOX_ENABLED" != 1 ]; then
    return 0
  fi
  sandbox_require
  printf '%s --settings %s -c' "$(sandbox_squote "$SANDBOX_SRT")" "$(sandbox_squote "$SANDBOX_SETTINGS")"
}

cmd_exec() {
  local joined item
  if [ "$SANDBOX_ENABLED" != 1 ]; then
    exec "$@"
  fi
  sandbox_require
  joined=
  for item in "$@"; do
    joined="$joined$(sandbox_squote "$item") "
  done
  joined=${joined% }
  exec "$SANDBOX_SRT" --settings "$SANDBOX_SETTINGS" -c "$joined"
}

CONFIG=$(sandbox_config_dir) || exit 2
SANDBOX_ENABLED=$(fm_config_source_present "$CONFIG/worker-sandbox") || exit 1

case "${1:-}" in
  probe)
    shift
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    cmd_probe
    ;;
  prefix)
    shift
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    cmd_prefix
    ;;
  exec)
    shift
    [ "${1:-}" = "--" ] || { usage >&2; exit 2; }
    shift
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    cmd_exec "$@"
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
