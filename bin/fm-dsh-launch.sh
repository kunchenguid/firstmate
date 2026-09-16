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
#   FM_ROOT             this checkout. .dsh/profile.patch.yml resolves the hooks
#                       bridge's configPath and projectDir from it, so it is set
#                       from this script's own location, never inherited.
#   LC_ALL / LC_CTYPE   a locale. Unset, bin/fm-line-cap-lib.sh's character cap
#                       becomes a byte cap and slices UTF-8 mid-character.
#   DSH_PERMISSION_MODE the host's sandbox-policy mode, which dsh-base reads at
#                       start. Hooks run with no session, so this mode - not a
#                       session's permission preset - decides whether `ps` works
#                       in every firstmate hook. Overridden, not defaulted: an
#                       inherited workspace-write would silently break them.
#
# DSH takes the invoking directory as its workspace root, so the host is started
# from this checkout whatever directory the operator launched from.
#
# Foreign harness markers are cleared so a session started from another
# harness's pane cannot inherit its identity. bin/fm-spawn.sh does the same at
# its own launch boundaries.
#
# Usage: bin/fm-dsh-launch.sh [dsh arguments...]      e.g. ... web --port 3080
set -u

ROOT=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

export FM_DSH_HARNESS=dsh
export FM_ROOT="$ROOT"
export FM_HOME="${FM_HOME:-$ROOT}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-en_US.UTF-8}"
export DSH_PERMISSION_MODE=danger-full-access

unset CLAUDECODE CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI ATLASSIAN_AGENT_TYPE \
  ROVODEV_CLI PI_CODING_AGENT FM_PI_HARNESS FM_OMP_HARNESS 2>/dev/null || true
# GROK_* are checked by name so an unset variable never trips `set -u`.
unset GROK_AGENT GROK_HOOK_EVENT GROK_SESSION_ID GROK_WORKSPACE_ROOT 2>/dev/null || true

# Assert the three DSH misconfigurations that fail silently, before a session
# starts depending on them. FM_DSH_SKIP_PREFLIGHT=1 is the escape hatch for a
# deliberately degraded home.
if [ "${FM_DSH_SKIP_PREFLIGHT:-}" != 1 ] && [ -x "$ROOT/bin/fm-dsh-preflight.sh" ]; then
  PROFILE=web
  PATCHES=()
  want=
  for arg in "$@"; do
    case "$want" in
      profile) PROFILE=$arg; want=; continue ;;
      patch) PATCHES+=(--patch "$arg"); want=; continue ;;
    esac
    case "$arg" in
      --profile) want='profile' ;;
      --profile=*) PROFILE=${arg#--profile=} ;;
      --patch) want='patch' ;;
      --patch=*) PATCHES+=(--patch "${arg#--patch=}") ;;
      web|headless|acp|sdk|sdk-minimal) [ "$arg" = web ] || PROFILE=$arg ;;
    esac
  done
  "$ROOT/bin/fm-dsh-preflight.sh" --profile "$PROFILE" --home "$ROOT" ${PATCHES[@]+"${PATCHES[@]}"} || exit 3
fi

exec dsh "$@"
