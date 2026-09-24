#!/usr/bin/env bash
# fm-jcode-seed.sh - deliver a jcode crewmate's launch brief.
#
# Every other verified adapter takes its brief as a command-line positional:
#
#   harness __MODELFLAG__ "$(fm-operational-input.sh encode launch-brief < brief.md)"
#
# jcode cannot. Verified 2026-09-09 on v0.84.0: a positional is parsed as a
# SUBCOMMAND ("error: unrecognized subcommand"), there is no --prompt flag, and
# `jcode run <MSG>` is headless single-shot, which exits instead of leaving the
# supervised pane a crewmate needs.
#
# The daemon CAN be driven directly - `jcode debug -S <id> message:<text>` works
# and lands in session history - but the TUI does NOT render debug-injected
# turns (verified: the exchange appeared in `history` while the pane stayed
# empty). Firstmate supervises a WATCHABLE pane, so that route would hide the
# crewmate's work from the captain and is deliberately not used here.
#
# So the brief is TYPED into the composer, which renders normally. It is typed
# as a one-line POINTER rather than the brief body, because
# fm-operational-input.sh's encoding preserves newlines and a newline in a TUI
# composer submits: a multi-line brief would fragment into several turns. The
# body stays on disk, which is where firstmate's own contract already says the
# durable instruction lives.
#
# Usage:
#   fm-jcode-seed.sh <backend> <target> <working-dir> <brief-path>
#                    [--timeout <secs>] [--effort <level>]
#
# This mirrors the kimi pointer path already in bin/fm-spawn.sh, which exists
# for the same reason: a harness that cannot take its brief as a positional.
# Like kimi, a non-empty submit verdict is NOT treated as failure - only an
# outright send-failed is - because the composer verdict is a delivery guard,
# not proof. jcode can do better than kimi's timed wait: the daemon's own
# is_processing flipping true IS the proof that the brief started a turn, so
# that is what confirms delivery here.
#
# --effort is delivered as jcode's /effort slash command BEFORE the brief,
# because jcode exposes no launch-time effort flag (verified v0.84.0: effort is
# /effort only). Without this a jcode crewmate could never honour a dispatch
# profile's effort axis.
#
# Exit: 0 brief delivered and confirmed; 1 timed out waiting for the session or
# delivery unconfirmed; 2 usage.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$here/fm-backend.sh" || { echo "fm-jcode-seed: cannot source fm-backend.sh" >&2; exit 2; }

usage() { echo "usage: fm-jcode-seed.sh <backend> <target> <working-dir> <brief-path> [--timeout <secs>]" >&2; exit 2; }

backend=${1-}; target=${2-}; working_dir=${3-}; brief=${4-}
[ -n "$backend" ] && [ -n "$target" ] && [ -n "$working_dir" ] && [ -n "$brief" ] || usage
shift 4
timeout_s=180
effort=
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) timeout_s=${2-}; shift 2 || usage ;;
    --effort) effort=${2-}; shift 2 || usage ;;
    *) usage ;;
  esac
done
[ -f "$brief" ] || { echo "fm-jcode-seed: no brief at $brief" >&2; exit 2; }
brief=$(cd "$(dirname "$brief")" && pwd -P)/$(basename "$brief")
working_dir=$(cd "$working_dir" 2>/dev/null && pwd -P) || {
  echo "fm-jcode-seed: unreadable working dir" >&2; exit 2; }

# Wait for the daemon to register a READY session for this worktree. Typing
# before the composer exists silently drops the brief, which would leave a
# crewmate sitting idle with no instruction and no error.
waited=0
while :; do
  ready=$(JCODE_DEBUG_CONTROL=1 jcode debug sessions 2>/dev/null \
    | jq -r --arg wd "$working_dir" '
        (. // []) | map(select(.working_dir == $wd)) | .[0]
        | if . == null then empty
          elif (.is_processing | not) and (.status == "ready") then "ready"
          else empty end' 2>/dev/null)
  [ "$ready" != ready ] || break
  waited=$((waited + 1))
  if [ "$waited" -ge "$timeout_s" ]; then
    echo "fm-jcode-seed: no ready jcode session for $working_dir within ${timeout_s}s" >&2
    exit 1
  fi
  sleep 1
done

# One line, same operational-input protocol every other adapter's brief carries,
# so firstmate-aware parsing still classifies it as a launch-brief.
pointer="Your complete instruction set is the brief at $brief - read that file now and execute it. Do not wait for further input."
text=$(printf '%s' "$pointer" | "$here/fm-operational-input.sh" encode launch-brief) || {
  echo "fm-jcode-seed: could not encode the launch brief" >&2; exit 1; }

# Set effort first, as its own submitted line, so the brief turn runs at the
# dispatch profile's level rather than jcode's default.
if [ -n "$effort" ]; then
  case "$effort" in
    none|minimal|low|medium|high|xhigh|max)
      fm_backend_send_text_submit "$backend" "$target" "/effort $effort" 3 0.4 1.5 effort >/dev/null
      sleep 1
      ;;
    swarm|swarm-deep)
      # jcode's swarm efforts make the agent spawn and coordinate its OWN
      # workers. Firstmate owns dispatch: a crewmate that fans out on its own
      # produces agents with no task record, no worktree, and no supervision.
      echo "fm-jcode-seed: refusing effort '$effort': firstmate owns dispatch, jcode swarm efforts are not selectable" >&2
      exit 1
      ;;
    *) echo "fm-jcode-seed: ignoring unsupported effort '$effort'" >&2 ;;
  esac
fi

# A non-empty verdict is a delivery GUARD, not disproof (same call shape kimi
# uses); only send-failed means the text never reached the composer.
verdict=$(fm_backend_send_text_submit "$backend" "$target" "$text" 3 0.4 1.5 launch-brief)
if [ "$verdict" = send-failed ]; then
  echo "fm-jcode-seed: launch brief could not be typed into $target" >&2
  exit 1
fi

# PROOF: the daemon must show this worktree's session actually processing. That
# is what distinguishes a delivered brief from one that silently went nowhere.
waited=0
while :; do
  busy=$(JCODE_DEBUG_CONTROL=1 jcode debug sessions 2>/dev/null     | jq -r --arg wd "$working_dir" '(. // []) | map(select(.working_dir == $wd)) | .[0]
        | if . != null and .is_processing then "busy" else empty end' 2>/dev/null)
  [ "$busy" != busy ] || break
  waited=$((waited + 1))
  if [ "$waited" -ge 60 ]; then
    echo "fm-jcode-seed: brief typed but no turn started within 60s (verdict=$verdict)" >&2
    exit 1
  fi
  sleep 1
done
echo "fm-jcode-seed: launch brief delivered and turn confirmed on $target"
exit 0
