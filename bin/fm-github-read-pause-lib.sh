#!/usr/bin/env bash
# Shared durable no-GitHub-read pause primitives.
#
# The marker is state/.github-read-pause with exactly one version line. Any
# object at that path suppresses GitHub reader registration, including an
# invalid or unreadable object: ambiguity must not silently release a
# credential-safety pause. bin/fm-github-read-pause.sh is the only marker owner.
# Callers serialize marker inspection and reader publication on
# state/.github-read-pause.lock through fm-wake-lib.sh's lock helpers.

fm_github_read_pause_marker() {  # <state>
  printf '%s/.github-read-pause\n' "$1"
}

fm_github_read_pause_active() {  # <state>
  local marker
  marker=$(fm_github_read_pause_marker "$1")
  [ -e "$marker" ] || [ -L "$marker" ]
}

fm_github_read_pause_valid() {  # <state>
  local state=$1 marker device
  marker=$(fm_github_read_pause_marker "$state")
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$marker" 600 "$device" || return 1
  [ "$(cat "$marker" 2>/dev/null)" = fm-github-read-pause-v1 ]
}
