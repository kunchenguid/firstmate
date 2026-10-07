#!/usr/bin/env bash
# fm-launch-secrets-lib.sh - launch a worker with named secrets injected by a
# secret manager, so each secret reaches only that worker's process
# environment. Sourced by bin/fm-spawn.sh (fresh spawn and --relaunch, which
# bin/fm-control.sh relaunch drives). Sourcing has no side effects.
#
# Configuration: config/launch-secrets.json, opt-in and home-local; absent
# means every launch is unchanged. docs/configuration.md "Worker launch
# secrets" owns the schema.
#
# Only secret NAMES ever enter Firstmate text: the staged launch file, the
# task record, status lines, and spawn output carry names, never values. The
# value exists only inside the injector and the process tree it starts. A
# failed launch copies the pane's last lines into the status and spawn output,
# so the injector must never print a value (shell tracing included).
#
# Launch handshake. The injector runs in the pane, so a refusal (a denied or
# timed-out vault approval, a missing secret) happens after the spawn handed
# the pane its launch. The wrapped launch therefore races the spawn for one
# claim directory with mkdir, which is atomic:
#   - the injected shell claims it first and only then starts the worker;
#   - if the injector returns without that claim, the pane writes the exit
#     status to the refusal file;
#   - if neither appears in time, the spawn claims the directory itself, so a
#     late approval can no longer start the worker the spawn already failed.
# The spawn proceeds only on the worker's own claim; every other outcome stops
# the spawn with the concrete reason.
#
# Unattended launches cannot wait on an interactive approval. The watcher's
# automatic secondmate respawn bounds the whole spawn with its own timeout
# (FM_SECONDMATE_LIVENESS_TIMEOUT, default 120s), so an injector that waits on
# a human approval past it fails that respawn closed, through the claim above;
# every automatic retry fails the same way until a hand relaunch. Such a
# harness needs an injector that answers without a prompt for unattended
# respawns to succeed.

# fm_launch_secrets_load <config-dir> <harness>
# Validates config/launch-secrets.json and selects the secrets for <harness>.
# Sets FM_LAUNCH_SECRETS_NAMES (space-separated names; empty when the file is
# absent or names nothing for this harness) and FM_LAUNCH_SECRETS_INJECTOR
# (the shell-quoted injector argv prefix, with argv[0] resolved to an
# executable path), and defaults FM_LAUNCH_SECRETS_TIMEOUT to 300 seconds.
# Returns 1 with an error on stderr for an unreadable or malformed file, an
# injector that is not installed, or a timeout that is not a non-negative
# integer.
fm_launch_secrets_load() {
  local config=$1 harness=$2 file present argv0 resolved rest
  file=$config/launch-secrets.json
  FM_LAUNCH_SECRETS_NAMES=
  FM_LAUNCH_SECRETS_INJECTOR=
  present=$(fm_config_source_present "$file") || return 1
  [ "$present" = 1 ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/launch-secrets.json must be a readable regular file" >&2
    return 1
  fi
  if ! jq -e '
    type == "object" and (keys - ["injector", "harnesses"] | length == 0) and
    (.injector | type == "array" and length > 1 and all(.[]; type == "string" and length > 0) and
      (.[0] | contains("{name}") | not) and any(.[]; contains("{name}"))) and
    (.harnesses | type == "object" and all(.[];
      type == "array" and length > 0 and length == (unique | length) and
      all(.[]; type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$"))))
  ' "$file" >/dev/null 2>&1; then
    echo "error: config/launch-secrets.json must be {\"injector\": [<command>, <args>...], \"harnesses\": {<harness>: [<SECRET_NAME>...]}}, with at least one injector element containing {name} (not the command itself) and each harness naming distinct environment variable names (see docs/configuration.md \"Worker launch secrets\")" >&2
    return 1
  fi
  FM_LAUNCH_SECRETS_NAMES=$(jq -r --arg h "$harness" '(.harnesses[$h] // []) | join(" ")' "$file") || return 1
  [ -n "$FM_LAUNCH_SECRETS_NAMES" ] || return 0
  FM_LAUNCH_SECRETS_TIMEOUT=${FM_LAUNCH_SECRETS_TIMEOUT:-300}
  case "$FM_LAUNCH_SECRETS_TIMEOUT" in
  *[!0-9]*)
    echo "error: FM_LAUNCH_SECRETS_TIMEOUT must be a non-negative integer number of seconds, not '$FM_LAUNCH_SECRETS_TIMEOUT'; refusing to launch the $harness worker with its secrets ($FM_LAUNCH_SECRETS_NAMES)" >&2
    FM_LAUNCH_SECRETS_NAMES=
    return 1
    ;;
  esac
  argv0=$(jq -r '.injector[0]' "$file") || return 1
  resolved=$(command -v -- "$argv0" 2>/dev/null) || resolved=
  case "$resolved" in
  /*) [ -x "$resolved" ] || resolved= ;;
  *) resolved= ;;
  esac
  if [ -z "$resolved" ]; then
    echo "error: config/launch-secrets.json names injector '$argv0' for harness $harness, but it is not an installed executable; refusing to launch the worker without its secrets ($FM_LAUNCH_SECRETS_NAMES)" >&2
    FM_LAUNCH_SECRETS_NAMES=
    return 1
  fi
  rest=$(jq -r --arg h "$harness" '
    .harnesses[$h] as $names |
    [.injector[1:][] | if contains("{name}") then ($names[] as $n | gsub("\\{name\\}"; $n)) else . end] |
    map(@sh) | join(" ")
  ' "$file") || return 1
  FM_LAUNCH_SECRETS_INJECTOR="$(fm_launch_secrets_quote "$resolved") $rest"
}

# fm_launch_secrets_wrap <launch> <claim-dir> <refused-file>
# Prints <launch> wrapped in the loaded injector and the launch handshake.
# <launch> must be POSIX sh, because it runs under /bin/sh -c inside the
# injector. The surrounding lines run in the pane shell that sources the
# staged launch file.
fm_launch_secrets_wrap() {
  local launch=$1 claim=$2 refused=$3 qclaim qrefused inner
  qclaim=$(fm_launch_secrets_quote "$claim")
  qrefused=$(fm_launch_secrets_quote "$refused")
  inner="mkdir $qclaim 2>/dev/null || { echo 'error: the spawn already gave up on this launch; not starting the worker' >&2; exit 125; }; $launch"
  # The status expansions belong to the pane shell, not to this function.
  # shellcheck disable=SC2016
  printf '%s /bin/sh -c %s; fm_launch_secrets_status=$?; [ -d %s ] || { printf %s "$fm_launch_secrets_status" >%s && mv -f %s %s; }; unset fm_launch_secrets_status\n' \
    "$FM_LAUNCH_SECRETS_INJECTOR" "$(fm_launch_secrets_quote "$inner")" "$qclaim" \
    "'%s\n'" "$(fm_launch_secrets_quote "$refused.tmp")" "$(fm_launch_secrets_quote "$refused.tmp")" "$qrefused"
}

# fm_launch_secrets_quote <text>: one single-quoted POSIX shell word.
fm_launch_secrets_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_launch_secrets_pane_reason <pane-capture>
# Prints the capture's last three non-empty lines on one line, so a refusal
# keeps the injector's own message after the spawn closes the pane. The
# capture is unfiltered, so this relies on the injector never printing a value.
fm_launch_secrets_pane_reason() {
  printf '%s\n' "$1" | awk '
    { gsub(/\r/, ""); sub(/[[:space:]]+$/, "") }
    length { line[++n] = $0 }
    END {
      first = n > 3 ? n - 2 : 1
      for (i = first; i <= n; i++) printf "%s%s", (i > first ? " | " : ""), line[i]
    }'
}

# fm_launch_secrets_wait <claim-dir> <refused-file> <timeout-seconds>
# Waits for the launch handshake above. Returns 0 once the injected worker
# holds the claim. Otherwise prints the concrete reason on stdout and returns
# 1; on a timeout it first takes the claim so the worker can never start late.
fm_launch_secrets_wait() {
  local claim=$1 refused=$2 timeout=$3 interval=${FM_LAUNCH_SECRETS_POLL:-0.2} start now status
  start=$(date +%s)
  while :; do
    [ ! -d "$claim" ] || return 0
    if [ -s "$refused" ]; then
      status=$(head -n 1 "$refused" 2>/dev/null)
      case "$status" in
      0) printf 'the secret injector exited without starting the worker' ;;
      '' | *[!0-9]*) printf 'the secret injector stopped before starting the worker' ;;
      *) printf 'the secret injector refused (exit %s) before starting the worker' "$status" ;;
      esac
      return 1
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout" ]; then
      if mkdir "$claim" 2>/dev/null; then
        printf 'the secret injector did not start the worker within %ss (a pending approval?)' "$timeout"
        return 1
      fi
      return 0
    fi
    sleep "$interval"
  done
}
