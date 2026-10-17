# shellcheck shell=bash
# fm-home-drift-lib.sh - warn loudly when an inherited FM_HOME disagrees with
# the firstmate checkout enclosing the caller's working directory.
#
# The hazard (issue #2002): a shell that is not a firstmate pane can carry a
# sibling home's FM_HOME in its inherited environment - the tmux server's env,
# a stale export, or a launch prefix from another home. From that shell the
# cwd still looks like the right home, yet every bare bin/fm-*.sh resolves
# state, locks, sends, and the wake queue against the sibling. The drift is
# invisible until a command mutates the wrong home's durable records, and it
# is exactly why bin/fm-send.sh refuses an absent FM_HOME rather than guessing.
#
# This library makes the drift visible instead of silent. Sourced by every
# bin/fm-*.sh entrypoint right after its FM_HOME resolution, so each direct
# invocation re-checks the environment it was handed.
#
# fm_home_drift_warn prints one stderr warning when ALL of these hold:
#
#   1. FM_HOME is set and nonempty. An unset or empty FM_HOME resolves to the
#      invoked checkout's own root, so there is nothing to disagree with.
#   2. No directory-relocating FM_*_OVERRIDE carries a value. A caller passing
#      a home plus explicit directory overrides (fm-remote-secondmate-control,
#      teardown's per-home sweeps, seeded provisioning, the test sandbox) is
#      deliberately addressing that home - explicit, not inferred - and a
#      warning would only hide real drift behind routine noise. Non-directory
#      knobs such as FM_TIMEOUT_MECHANISM_OVERRIDE do not qualify.
#   3. The caller's working directory sits inside a firstmate checkout whose
#      canonical path differs from FM_HOME's. Walked up through ancestor
#      directories, the first directory holding bin/fm-session-start.sh is the
#      enclosing checkout - the home the shell visibly sits in. Outside any
#      checkout the operator is simply addressing FM_HOME by name and there
#      is no misleading home context to warn about.
#
#   4. The caller is not the test harness itself. tests/lib.sh exports
#      FM_TEST_SEAM=1 and deliberately pins FM_HOME to scratch homes while
#      cwd sits inside the repo checkout - that is the sanctioned test
#      sandbox, the same pattern FM_GATE_REFUSE_BYPASS covers, and the warn
#      would only fight the suite.
#
# The check is deliberately not "FM_HOME differs from the script's own code
# root": FM_ROOT != FM_HOME is by itself no violation, because callers
# legitimately run one checkout's scripts against another home's directories
# through overrides - and drift can target any of them: a shell inside one
# checkout carrying a sibling home's FM_HOME (checkout or data-only
# operational home alike) mutates that home's state with no outward sign. The
# leak this warns on is the opposite signal - the shell presents one home
# while the environment commands another.
#
# It stays a warning, never a refusal: legitimate cross-home addressing must
# keep working, and a refusal would turn supported layouts into failures. The
# remediation it names is explicit - unset FM_HOME, or pin it to the enclosing
# home - which is also the only form the watcher arm policy newly blesses.
#
# Sourced, never executed: no side effects on source; set -u / set -e safe.

# fm_home_drift_enclosing <dir>: print the canonical path of the nearest
# ancestor-or-self directory that looks like a firstmate checkout (holds
# bin/fm-session-start.sh); return 1 when <dir> is unreachable or no ancestor
# qualifies. The walk strips one component per step and bottoms out at /, so
# it terminates by construction at any depth.
fm_home_drift_enclosing() {
  local dir=${1:-$PWD}
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  # Each iteration strips one component and bottoms out at /, so the loop
  # always terminates.
  while :; do
    if [ -f "$dir/bin/fm-session-start.sh" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    [ "$dir" = / ] && return 1
    dir=${dir%/*}
    [ -n "$dir" ] || dir=/
  done
}

# fm_home_drift_warn: emit the drift warning described above, or nothing.
fm_home_drift_warn() {
  local home=${FM_HOME:-} resolved enclosing v
  [ -n "$home" ] || return 0
  # The test harness pins FM_HOME to scratch homes from inside the repo by
  # design; its seam marks that deliberate sandbox so the warn stays quiet.
  [ "${FM_TEST_SEAM:-}" = 1 ] && return 0
  # Only a nonempty directory-relocating override marks deliberate cross-home
  # addressing; unrelated FM_*_OVERRIDE knobs (timeout mechanism, remote-job
  # platform pin, /proc root, harness test seams) must not silence the warn.
  for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
           FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE \
           FM_PENDING_REPLY_DIR_OVERRIDE \
           FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE; do
    [ -z "${!v:-}" ] || return 0
  done
  resolved=$(cd "$home" 2>/dev/null && pwd -P || printf '%s' "${home%/}")
  enclosing=$(fm_home_drift_enclosing "${PWD:-.}") || return 0
  [ "$enclosing" = "$resolved" ] && return 0
  printf "warning: FM_HOME '%s' disagrees with the enclosing checkout '%s' - commands act on FM_HOME; unset FM_HOME or pin FM_HOME='%s' to command this checkout's own home\n" \
    "$home" "$enclosing" "$enclosing" >&2
}
