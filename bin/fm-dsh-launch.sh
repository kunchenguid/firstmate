#!/usr/bin/env bash
# Launch DeepSeek Harness as a firstmate PRIMARY, with the launch-time
# environment the DSH adapter requires.
#
# Every value here must exist at process start: a DSH tool call cannot set an
# environment variable for its own host, and hook and tool subprocesses inherit
# whatever the host process was given. Setting them in documentation instead of
# at a launch boundary is how a home silently identifies as the wrong harness.
#
#   FM_DSH_HARNESS=dsh  DeepSeek Harness publishes NO identity marker of its own
#                       (the host is a node process, so `ps` reports comm=node
#                       and only argv identifies it). This Firstmate-owned
#                       marker is what lets bin/fm-harness.sh identify the home
#                       instead of a retained fallback marker.
#   FM_HOME             the home this session owns, which bin/fm-send.sh and the
#                       session lock both need explicitly.
#   LC_ALL / LC_CTYPE   a locale. Unset, bin/fm-line-cap-lib.sh's character cap
#                       becomes a byte cap and slices UTF-8 mid-character.
#
# Foreign harness markers are cleared so a session started from another
# harness's pane cannot inherit its identity. bin/fm-spawn.sh does the same at
# its own launch boundaries.
#
# Usage: bin/fm-dsh-launch.sh [dsh arguments...]      e.g. ... web --port 3080
set -u

ROOT=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export FM_DSH_HARNESS=dsh
export FM_HOME="${FM_HOME:-$ROOT}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-en_US.UTF-8}"

unset CLAUDECODE CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI ATLASSIAN_AGENT_TYPE \
  ROVODEV_CLI PI_CODING_AGENT FM_PI_HARNESS FM_OMP_HARNESS 2>/dev/null || true
# GROK_* are checked by name so an unset variable never trips `set -u`.
unset GROK_AGENT GROK_HOOK_EVENT GROK_SESSION_ID GROK_WORKSPACE_ROOT 2>/dev/null || true

exec dsh "$@"
